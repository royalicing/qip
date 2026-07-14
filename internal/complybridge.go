// Content Compliance bridge: the host side of the qip.* import ABI for
// Compliance components that own their memory and declare cases by ordinal.
//
// Bridge ABI (module "qip"; every call carries the component's u64 case
// ordinal so both sides continuously verify they agree on which case this is):
//
//	render_must_equal(ordinal, in_ptr, in_len, expected_ptr, expected_len) -> i32
//	render_must_trap(ordinal, in_ptr, in_len) -> i32
//	render_examine(ordinal, in_ptr, in_len, out_ptr, out_cap) -> i32
//	render_examine_pass(ordinal) -> i32
//	render_examine_fail(ordinal) -> i32
//	set_uniform_u32(name_ptr, name_len, value) -> i32
//
// The component exports comply() -> i32 (declared-case count) and optionally
// uniform_set_seed(i32). The host owns all data movement (memcpy between the
// component's and the implementation's memories), comparison, and reporting;
// there are no failure_* exports and no case names on the wire — a failing
// case is identified as (component, seed, ordinal).
package qinternal

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero/api"
)

const (
	bridgeHostModuleName  = "qip"
	bridgeExportComply    = "comply"
	bridgeExportSetSeed   = "uniform_set_seed"
	bridgeMaxFailureNotes = 5
)

// isBridgeCompliance reports whether the module targets the bridge ABI,
// which its comply() export declares.
func isBridgeCompliance(wasm []byte) bool {
	ctx := context.Background()
	r := wasmruntime.NewRunToCompletion(ctx)
	defer r.Close(ctx)
	compiled, err := r.CompileModule(ctx, wasm)
	if err != nil {
		return false
	}
	defer compiled.Close(ctx)
	_, ok := compiled.ExportedFunctions()[bridgeExportComply]
	return ok
}

type bridgeFailure struct {
	ordinal  uint64
	kind     string
	input    []byte
	expected []byte
	actual   []byte
}

type bridgeState struct {
	implMod     api.Module
	renderFn    api.Function
	implInPtr   uint32
	implInCap   uint32
	next        uint64
	openExamine *uint64
	failures    []bridgeFailure
	failCount   int
	protocolErr error
}

func (s *bridgeState) protocolViolation(format string, args ...any) {
	if s.protocolErr == nil {
		s.protocolErr = fmt.Errorf(format, args...)
	}
}

func (s *bridgeState) recordFailure(f bridgeFailure) {
	s.failCount++
	if len(s.failures) < bridgeMaxFailureNotes {
		s.failures = append(s.failures, f)
	}
}

// renderImpl copies input into the implementation and renders, returning the
// output bytes (a view into impl memory, valid until the next render).
func (s *bridgeState) renderImpl(ctx context.Context, input []byte) ([]byte, error) {
	if uint32(len(input)) > s.implInCap {
		return nil, fmt.Errorf("input length %d exceeds implementation input cap %d", len(input), s.implInCap)
	}
	if !s.implMod.Memory().Write(s.implInPtr, input) {
		return nil, errors.New("implementation input buffer out of range")
	}
	res, err := s.renderFn.Call(ctx, uint64(uint32(len(input))))
	if err != nil {
		return nil, err
	}
	outLen := api.DecodeU32(res[0])
	outPtr, ok, err := getExportedI32(ctx, s.implMod, "output_ptr")
	if err != nil || !ok {
		return nil, errors.New("implementation output_ptr unavailable after render")
	}
	out, ok := s.implMod.Memory().Read(uint32(outPtr), outLen)
	if !ok {
		return nil, errors.New("implementation output out of range")
	}
	return out, nil
}

// The named return matters: out.duration is assigned in a defer, which only
// reaches the caller's copy through the named result.
func runBridgeComplianceModule(implWasm []byte, compliance complianceSpec, seed *int32) (out complianceOutcomes) {
	out = complianceOutcomes{index: compliance.index, path: compliance.path}
	start := time.Now()
	defer func() { out.duration = time.Since(start) }()

	ctx := context.Background()
	r := wasmruntime.NewRunToCompletion(ctx)
	defer r.Close(ctx)

	implMod, err := r.Instantiate(ctx, implWasm)
	if err != nil {
		out.err = errors.New("implementation module could not be instantiated")
		return out
	}
	defer implMod.Close(ctx)

	state := &bridgeState{implMod: implMod}
	state.renderFn = implMod.ExportedFunction(complyExportRun)
	if state.renderFn == nil {
		out.err = errors.New("bridge compliance requires implementation export render(i32) -> i32")
		return out
	}
	inPtr, ok, err := getExportedI32(ctx, implMod, complyExportInputPtr)
	if err != nil || !ok {
		out.err = errors.New("implementation input_ptr unavailable")
		return out
	}
	state.implInPtr = uint32(inPtr)
	inCap, ok, err := getExportedI32(ctx, implMod, complyExportInputUTF8Cap)
	if err != nil || !ok {
		inCap, ok, err = getExportedI32(ctx, implMod, complyExportInputBytesCap)
		if err != nil || !ok {
			out.err = errors.New("implementation input cap unavailable")
			return out
		}
	}
	state.implInCap = uint32(inCap)

	readChecker := func(m api.Module, ptr, length uint32) ([]byte, bool) {
		return m.Memory().Read(ptr, length)
	}
	caseOpen := func(ordinal uint64, kind string) bool {
		if state.openExamine != nil {
			state.protocolViolation("%s at ordinal %d inside open examination %d", kind, ordinal, *state.openExamine)
			return false
		}
		if ordinal != state.next {
			state.protocolViolation("%s declared ordinal %d, host expected %d", kind, ordinal, state.next)
			return false
		}
		return true
	}
	setUniformU32 := func(callCtx context.Context, m api.Module, namePtr, nameLen, value uint32) uint32 {
		if state.openExamine != nil {
			state.protocolViolation("set_uniform_u32 called inside open examination %d", *state.openExamine)
			return 0
		}
		if nameLen == 0 || nameLen > 128 {
			state.protocolViolation("set_uniform_u32 name length %d is outside 1..128", nameLen)
			return 0
		}
		nameBytes, ok := readChecker(m, namePtr, nameLen)
		if !ok {
			state.protocolViolation("set_uniform_u32 name pointer out of range")
			return 0
		}
		for _, b := range nameBytes {
			if !((b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '_') {
				state.protocolViolation("set_uniform_u32 name %q is not a lowercase uniform key", string(nameBytes))
				return 0
			}
		}

		exportName := "uniform_set_" + string(nameBytes)
		setter := state.implMod.ExportedFunction(exportName)
		if setter == nil {
			state.protocolViolation("implementation does not export %s", exportName)
			return 0
		}
		if err := requireSignature(setter.Definition(), []api.ValueType{api.ValueTypeI32}, []api.ValueType{api.ValueTypeI32}, exportName); err != nil {
			state.protocolViolation("%v", err)
			return 0
		}
		result, err := setter.Call(callCtx, uint64(value))
		if err != nil {
			state.protocolViolation("%s trapped: %v", exportName, err)
			return 0
		}
		return api.DecodeU32(result[0])
	}

	_, err = r.NewHostModuleBuilder(bridgeHostModuleName).
		NewFunctionBuilder().
		WithFunc(setUniformU32).
		Export("set_uniform_u32").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, m api.Module, ordinal uint64, inPtr, inLen, expPtr, expLen uint32) int32 {
			if !caseOpen(ordinal, "render_must_equal") {
				return 0
			}
			state.next++
			input, ok1 := readChecker(m, inPtr, inLen)
			expected, ok2 := readChecker(m, expPtr, expLen)
			if !ok1 || !ok2 {
				state.protocolViolation("render_must_equal pointers out of range at ordinal %d", ordinal)
				return 0
			}
			actual, err := state.renderImpl(callCtx, input)
			if err != nil {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "trapped: " + err.Error(), input: bytes.Clone(input), expected: bytes.Clone(expected)})
				return 0
			}
			if !bytes.Equal(actual, expected) {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "output mismatch", input: bytes.Clone(input), expected: bytes.Clone(expected), actual: bytes.Clone(actual)})
				return 0
			}
			return 1
		}).
		Export("render_must_equal").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, m api.Module, ordinal uint64, inPtr, inLen uint32) int32 {
			if !caseOpen(ordinal, "render_must_trap") {
				return 0
			}
			state.next++
			input, ok := readChecker(m, inPtr, inLen)
			if !ok {
				state.protocolViolation("render_must_trap pointer out of range at ordinal %d", ordinal)
				return 0
			}
			actual, err := state.renderImpl(callCtx, input)
			if err == nil {
				state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "expected trap, got output", input: bytes.Clone(input), actual: bytes.Clone(actual)})
				return 0
			}
			return 1
		}).
		Export("render_must_trap").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, m api.Module, ordinal uint64, inPtr, inLen, outPtr, outCap uint32) int32 {
			if state.openExamine == nil {
				if ordinal != state.next {
					state.protocolViolation("render_examine opened ordinal %d, host expected %d", ordinal, state.next)
					return -1
				}
				o := ordinal
				state.openExamine = &o
			} else if ordinal != *state.openExamine {
				state.protocolViolation("render_examine ordinal changed mid-case: %d then %d", *state.openExamine, ordinal)
				return -1
			}
			input, ok := readChecker(m, inPtr, inLen)
			if !ok {
				state.protocolViolation("render_examine pointer out of range at ordinal %d", ordinal)
				return -1
			}
			output, err := state.renderImpl(callCtx, input)
			if err != nil {
				return -1
			}
			if uint32(len(output)) > outCap {
				return -2
			}
			if !m.Memory().Write(outPtr, output) {
				state.protocolViolation("render_examine out pointer out of range at ordinal %d", ordinal)
				return -1
			}
			return int32(len(output))
		}).
		Export("render_examine").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, ordinal uint64) int32 {
			if state.openExamine != nil && *state.openExamine != ordinal {
				state.protocolViolation("render_examine_pass ordinal %d does not match open examination %d", ordinal, *state.openExamine)
				return 0
			}
			if ordinal != state.next {
				state.protocolViolation("render_examine_pass ordinal %d, host expected %d", ordinal, state.next)
				return 0
			}
			state.openExamine = nil
			state.next++
			return 1
		}).
		Export("render_examine_pass").
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, ordinal uint64) int32 {
			if state.openExamine != nil && *state.openExamine != ordinal {
				state.protocolViolation("render_examine_fail ordinal %d does not match open examination %d", ordinal, *state.openExamine)
				return 0
			}
			if ordinal != state.next {
				state.protocolViolation("render_examine_fail ordinal %d, host expected %d", ordinal, state.next)
				return 0
			}
			state.openExamine = nil
			state.next++
			state.recordFailure(bridgeFailure{ordinal: ordinal, kind: "examination failed"})
			return 1
		}).
		Export("render_examine_fail").
		Instantiate(ctx)
	if err != nil {
		out.err = fmt.Errorf("bridge host module could not be instantiated: %w", err)
		return out
	}

	checkerMod, err := r.Instantiate(ctx, compliance.wasm)
	if err != nil {
		out.err = fmt.Errorf("compliance component could not be instantiated (imports must bind to %q): %w", bridgeHostModuleName, err)
		return out
	}
	defer checkerMod.Close(ctx)

	if seed != nil {
		setSeed := checkerMod.ExportedFunction(bridgeExportSetSeed)
		if setSeed == nil {
			out.err = fmt.Errorf("--seed given but compliance component does not export %s", bridgeExportSetSeed)
			return out
		}
		if _, err := setSeed.Call(ctx, uint64(uint32(*seed))); err != nil {
			out.err = fmt.Errorf("%s failed: %w", bridgeExportSetSeed, err)
			return out
		}
	}

	complyFn := checkerMod.ExportedFunction(bridgeExportComply)
	res, err := complyFn.Call(ctx)
	if state.protocolErr != nil {
		out.err = fmt.Errorf("bridge protocol violation: %w", state.protocolErr)
		return out
	}
	if err != nil {
		out.err = fmt.Errorf("comply() trapped: %w", err)
		return out
	}
	if state.openExamine != nil {
		out.err = fmt.Errorf("comply() returned with examination %d still open", *state.openExamine)
		return out
	}
	declared := api.DecodeI32(res[0])
	if declared <= 0 {
		out.err = fmt.Errorf("comply() declared no cases (returned %d)", declared)
		return out
	}
	if uint64(uint32(declared)) != state.next&0x7FFFFFFF {
		out.err = fmt.Errorf("comply() returned %d cases but host counted %d", declared, state.next)
		return out
	}
	out.cases = state.next
	if state.failCount > 0 {
		out.err = fmt.Errorf("%d/%d cases failed", state.failCount, state.next)
		out.detail = bridgeFailureDetail(state)
		return out
	}

	out.passed = true
	return out
}

func bridgeFailureDetail(state *bridgeState) string {
	var parts []string
	for _, f := range state.failures {
		parts = append(parts, fmt.Sprintf("case %d: %s", f.ordinal, f.kind))
		if f.input != nil {
			parts = append(parts, "  input_utf8_preview="+previewUTF8(f.input))
			parts = append(parts, "  input_hex_preview="+previewHex(f.input))
		}
		if f.expected != nil {
			parts = append(parts, "  expected_output_hex_preview="+previewHex(f.expected))
		}
		if f.actual != nil {
			parts = append(parts, "  actual_output_hex_preview="+previewHex(f.actual))
		}
	}
	if state.failCount > len(state.failures) {
		parts = append(parts, fmt.Sprintf("… and %d more failing case(s); reproduce via (component, seed, ordinal)", state.failCount-len(state.failures)))
	}
	return strings.Join(parts, "\n")
}
