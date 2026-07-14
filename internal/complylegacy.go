// Legacy comply contract: compliance modules that share the implementation's
// linear memory (import impl.memory), export positive()/negative(), and
// report failures through failure_* exports. Superseded by the Content
// Compliance bridge (complybridge.go); runs only under --legacy.
//
// DELETE THIS FILE once the remaining legacy checkers (luhn, e164,
// commonmark, preserve-*, trap-invalid-utf8) are migrated to the bridge —
// nothing outside it references these functions or constants.
package qinternal

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

const (
	trapHostModuleName        = "qip"
	trapHostExportRunMustTrap = "render_must_trap"
	complyExportPositive      = "positive"
	complyExportNegative      = "negative"
)

// The named return matters: out.duration is assigned in a defer, which only
// reaches the caller's copy through the named result.
func runLegacyComplianceModule(implWasm []byte, compliance complianceSpec) (out complianceOutcomes) {
	out = complianceOutcomes{
		index: compliance.index,
		path:  compliance.path,
	}
	start := time.Now()
	defer func() { out.duration = time.Since(start) }()

	ctx := context.Background()
	r := wasmruntime.NewRunToCompletion(ctx)
	defer r.Close(ctx)

	implCompiled, err := r.CompileModule(ctx, implWasm)
	if err != nil {
		out.err = errors.New("implementation module could not be compiled")
		return out
	}
	defer implCompiled.Close(ctx)

	complianceCompiled, err := r.CompileModule(ctx, compliance.wasm)
	if err != nil {
		out.err = errors.New("compliance component could not be compiled")
		return out
	}
	defer complianceCompiled.Close(ctx)

	if err := ensurecomplianceImportsImplMemory(complianceCompiled); err != nil {
		out.err = err
		return out
	}

	hasNegative, err := ensureComplianceEntrypointSignatures(complianceCompiled)
	if err != nil {
		out.err = err
		return out
	}
	needsTrapHost := complianceNeedsTrapHost(complianceCompiled)

	_, detail, err := runCompliancePhase(ctx, r, implCompiled, complianceCompiled, complyExportPositive, needsTrapHost)
	if err != nil {
		out.err = err
		out.detail = detail
		return out
	}

	if hasNegative {
		_, detail, err = runCompliancePhase(ctx, r, implCompiled, complianceCompiled, complyExportNegative, true)
		if err != nil {
			out.err = err
			out.detail = detail
			return out
		}
	}

	out.passed = true
	return out
}

func ensurecomplianceImportsImplMemory(compiled wazero.CompiledModule) error {
	memImports := compiled.ImportedMemories()
	for _, mem := range memImports {
		mod, name, ok := mem.Import()
		if ok && mod == implModuleName && name == complyExportMemory {
			return nil
		}
	}
	return fmt.Errorf("compliance component must import %s.%s", implModuleName, complyExportMemory)
}

func ensureComplianceEntrypointSignatures(compiled wazero.CompiledModule) (bool, error) {
	def, ok := compiled.ExportedFunctions()[complyExportPositive]
	if !ok {
		return false, errors.New(`compliance component must export positive() -> i32`)
	}
	if err := requireSignature(def, []api.ValueType{}, []api.ValueType{api.ValueTypeI32}, complyExportPositive); err != nil {
		return false, errors.New(`compliance component export positive must have signature () -> i32`)
	}
	def, ok = compiled.ExportedFunctions()[complyExportNegative]
	if !ok {
		return false, nil
	}
	if err := requireSignature(def, []api.ValueType{}, []api.ValueType{api.ValueTypeI32}, complyExportNegative); err != nil {
		return false, errors.New(`compliance component export negative must have signature () -> i32`)
	}
	return true, nil
}

func complianceNeedsTrapHost(compiled wazero.CompiledModule) bool {
	for _, fn := range compiled.ImportedFunctions() {
		mod, name, ok := fn.Import()
		if ok && mod == trapHostModuleName && name == trapHostExportRunMustTrap {
			return true
		}
	}
	return false
}

func runCompliancePhase(
	ctx context.Context,
	r wazero.Runtime,
	implCompiled wazero.CompiledModule,
	complianceCompiled wazero.CompiledModule,
	entrypoint string,
	installTrapHost bool,
) (int32, string, error) {
	implMod, err := r.InstantiateModule(ctx, implCompiled, wazero.NewModuleConfig().WithName(implModuleName))
	if err != nil {
		return 0, "", errors.New("implementation module could not be instantiated")
	}
	defer implMod.Close(ctx)

	var trapHostMod api.Module
	if installTrapHost {
		trapHostMod, err = instantiateTrapHost(ctx, r, implMod)
		if err != nil {
			return 0, "", err
		}
		defer trapHostMod.Close(ctx)
	}

	complianceMod, err := r.InstantiateModule(ctx, complianceCompiled, wazero.NewModuleConfig().WithName("compliance-"+entrypoint))
	if err != nil {
		if installTrapHost {
			return 0, "", fmt.Errorf("compliance component could not be instantiated (imports must bind to %q and %q): %w", implModuleName, trapHostModuleName, err)
		}
		return 0, "", fmt.Errorf("compliance component could not be instantiated (imports must bind to %q): %w", implModuleName, err)
	}
	defer complianceMod.Close(ctx)

	fn := complianceMod.ExportedFunction(entrypoint)
	if fn == nil {
		return 0, "", fmt.Errorf(`compliance component must export %s() -> i32`, entrypoint)
	}

	complianceCtx := context.Background()

	res, err := fn.Call(complianceCtx)
	if err != nil {
		return 0, collectFailureDetail(complianceCtx, implMod, complianceMod), err
	}
	if len(res) != 1 {
		return 0, collectFailureDetail(complianceCtx, implMod, complianceMod), fmt.Errorf("%s() returned %d values, want 1", entrypoint, len(res))
	}

	status := api.DecodeI32(res[0])
	if status > 0 {
		return status, "", nil
	}
	if entrypoint == complyExportNegative {
		return status, collectFailureDetail(complianceCtx, implMod, complianceMod), errors.New("negative() expected trap")
	}
	return status, collectFailureDetail(complianceCtx, implMod, complianceMod), fmt.Errorf("positive() expected output (returned %d)", status)
}

func instantiateTrapHost(ctx context.Context, r wazero.Runtime, implMod api.Module) (api.Module, error) {
	runFn := implMod.ExportedFunction(complyExportRun)
	if runFn == nil {
		return nil, errors.New(`qip.render_must_trap requires implementation module export render(i32) -> i32`)
	}
	return r.NewHostModuleBuilder(trapHostModuleName).
		NewFunctionBuilder().
		WithFunc(func(callCtx context.Context, inputSize int32) int32 {
			_, err := runFn.Call(callCtx, uint64(uint32(inputSize)))
			if err != nil {
				return 1
			}
			return 0
		}).
		Export(trapHostExportRunMustTrap).
		Instantiate(ctx)
}

func collectFailureDetail(ctx context.Context, implMod api.Module, complianceMod api.Module) string {
	mem := implMod.Memory()
	if mem == nil {
		mem = complianceMod.Memory()
	}
	if mem == nil {
		return ""
	}

	var parts []string
	if msg := readFailureString(ctx, complianceMod, mem, []string{"failure_message", "fail_message"}); msg != "" {
		parts = append(parts, "message: "+msg)
	}
	if in, ok := readFailureBytesMaybe(ctx, complianceMod, mem, []string{"failure_input", "fail_input"}); ok {
		parts = append(parts, "input_utf8_preview="+previewUTF8(in))
		parts = append(parts, "input_hex_preview="+previewHex(in))
	}

	expectedOutput, hasExpectedOutput := readFailureBytesMaybe(
		ctx,
		complianceMod,
		mem,
		[]string{"failure_expected_output", "fail_expected_output"},
	)
	if hasExpectedOutput {
		parts = append(parts, "expected_output_utf8_preview="+previewUTF8(expectedOutput))
		parts = append(parts, "expected_output_hex_preview="+previewHex(expectedOutput))
	}

	actualOutput, hasActualOutput := readFailureBytesMaybe(
		ctx,
		complianceMod,
		mem,
		[]string{"failure_actual_output", "fail_actual_output"},
	)
	if !hasActualOutput {
		actualOutput, hasActualOutput = readFailureBytesMaybe(
			ctx,
			complianceMod,
			mem,
			[]string{"failure_output", "fail_output"},
		)
	}
	if hasActualOutput {
		parts = append(parts, "actual_output_utf8_preview="+previewUTF8(actualOutput))
		parts = append(parts, "actual_output_hex_preview="+previewHex(actualOutput))
	}
	if len(parts) == 0 {
		return "no failure detail exports found; optional exports: failure_message_ptr/size, failure_input_ptr/size, failure_expected_output_ptr/size, failure_actual_output_ptr/size"
	}
	return strings.Join(parts, "\n")
}

func readFailureString(ctx context.Context, mod api.Module, mem api.Memory, bases []string) string {
	data, ok := readFailureBytesMaybe(ctx, mod, mem, bases)
	if !ok || len(data) == 0 {
		return ""
	}
	return string(data)
}

func readFailureBytes(ctx context.Context, mod api.Module, mem api.Memory, bases []string) []byte {
	data, ok := readFailureBytesMaybe(ctx, mod, mem, bases)
	if !ok || len(data) == 0 {
		return nil
	}
	return data
}

func readFailureBytesMaybe(ctx context.Context, mod api.Module, mem api.Memory, bases []string) ([]byte, bool) {
	for _, base := range bases {
		ptrName := base + "_ptr"
		sizeName := base + "_size"
		ptr, ok, err := getExportedI32(ctx, mod, ptrName)
		if err != nil || !ok {
			continue
		}
		size, ok, err := getExportedI32(ctx, mod, sizeName)
		if err != nil || !ok {
			continue
		}
		if ptr < 0 || size < 0 {
			continue
		}
		if size == 0 {
			return []byte{}, true
		}
		raw, ok := mem.Read(uint32(ptr), uint32(size))
		if !ok {
			continue
		}
		clone := append([]byte(nil), raw...)
		return clone, true
	}
	return nil, false
}
