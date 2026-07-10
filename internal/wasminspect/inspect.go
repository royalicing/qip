package wasminspect

import (
	"errors"
	"fmt"
	"io"
	"strings"
)

type scoreMetrics struct {
	InstructionTotal int
	LoopCount        int
	BranchDecision   int // br_if + if
	BrTableCount     int
	BrTableTargets   int
	CallLocal        int
	CallIndirect     int
	CallImport       int
	LoopBackedge     int
}

type functionMetrics struct {
	InstructionTotal int
	LoopCount        int
	BranchDecision   int
	BrTableCount     int
	BrTableTargets   int
	CallLocal        int
	CallIndirect     int
	CallImport       int
	LoopBackedge     int
	ControlFlowOps   int
	LocalOps         int
	MemoryOps        int
	TableOps         int
}

type globalInitMetrics struct {
	InstructionTotal int
	SimpleConst      bool
	HasGlobalGet     bool
}

type instantiationMetrics struct {
	MemoryMinPages      uint64
	TableMinElements    uint64
	ActiveDataSegments  int
	ActiveDataBytes     uint64
	ActiveElemSegments  int
	ActiveElemElements  uint64
	HasStart            bool
	StartInstructionCnt int
	StartCalls          int
	StartBranches       int
	StartLoopBackedges  int
}

type memoryLimit struct {
	Imported bool
	Memory64 bool
	MinPages uint64
	HasMax   bool
	MaxPages uint64
}

type contractCheck struct {
	Export string
	Kind   string
	Pass   bool
	Reason string
}

type wasmExport struct {
	kind  byte
	index uint32
}

type wasmAnalysis struct {
	Metrics           scoreMetrics
	InstructionCounts map[InstructionOpcode]int
	LoopBoundFailures []LoopBoundFailure
	MemoryLimits      []memoryLimit
	CallEdges         []map[int]struct{}
	ImportedFuncCount int
	ImportedGlobals   int
	FuncMetrics       []functionMetrics
	GlobalMetrics     []globalInitMetrics
	Instantiation     instantiationMetrics
	Exports           map[string]wasmExport
}

type importCounts struct {
	Funcs        int
	Globals      int
	MemoryLimits []memoryLimit
}

type LoopBoundFailure struct {
	Function int
	Loop     int
	Reason   string
}

type loopCounterDirection uint8

const (
	loopCounterInc loopCounterDirection = 1 << iota
	loopCounterDec
)

type loopCounterEvidence struct {
	update loopCounterDirection
	exit   loopCounterDirection
}

type loopEvidence struct {
	index       int
	hasBackedge bool
	counters    map[uint32]loopCounterEvidence
}

type controlFrame struct {
	op      byte
	loopIdx int
}

type instrTrace struct {
	op     byte
	imm    int64
	hasImm bool
}

type boundCandidate struct {
	local     uint32
	direction loopCounterDirection
}

// Exported aliases for shared use by commands.
type ScoreMetrics = scoreMetrics
type FunctionMetrics = functionMetrics
type GlobalInitMetrics = globalInitMetrics
type InstantiationMetrics = instantiationMetrics
type MemoryLimit = memoryLimit
type ContractCheck = contractCheck
type Export = wasmExport
type Analysis = wasmAnalysis

const WasmPageSizeBytes uint64 = 65536

type InstructionOpcode uint32

const OpcodeMemoryGrow InstructionOpcode = 0x40

var instructionOpcodeNames = map[InstructionOpcode]string{
	OpcodeMemoryGrow: "memory.grow",
}

var qipContractExports = []string{
	"input_ptr",
	"input_utf8_cap",
	"input_bytes_cap",
	"output_ptr",
	"output_utf8_cap",
	"output_bytes_cap",
	"input_content_type_ptr",
	"input_content_type_size",
	"output_content_type_ptr",
	"output_content_type_size",
}

func AnalyzeModule(wasm []byte) (Analysis, error) {
	return analyzeWASMModule(wasm)
}

type ModulePolicy struct {
	MaxMemoryBytes      uint64
	RejectOpcodes       []InstructionOpcode
	RequireBoundedLoops bool
}

func ValidateModulePolicy(wasm []byte, policy ModulePolicy) error {
	if policy.MaxMemoryBytes == 0 && len(policy.RejectOpcodes) == 0 && !policy.RequireBoundedLoops {
		return nil
	}

	analysis, err := AnalyzeModule(wasm)
	if err != nil {
		return err
	}

	failures := make([]string, 0)
	if policy.MaxMemoryBytes > 0 {
		for i, memory := range analysis.MemoryLimits {
			minBytes, ok := pagesToBytes(memory.MinPages)
			if !ok || minBytes > policy.MaxMemoryBytes {
				failures = append(failures, fmt.Sprintf("memory[%d] initial size %d pages exceeds --max-memory %d bytes", i, memory.MinPages, policy.MaxMemoryBytes))
			}
			if !memory.HasMax {
				failures = append(failures, fmt.Sprintf("memory[%d] has no declared maximum", i))
				continue
			}
			maxBytes, ok := pagesToBytes(memory.MaxPages)
			if !ok || maxBytes > policy.MaxMemoryBytes {
				failures = append(failures, fmt.Sprintf("memory[%d] maximum %d pages exceeds --max-memory %d bytes", i, memory.MaxPages, policy.MaxMemoryBytes))
			}
		}
	}

	for _, opcode := range policy.RejectOpcodes {
		if count := analysis.InstructionCounts[opcode]; count > 0 {
			failures = append(failures, fmt.Sprintf("violates fixed-memory policy: contains %s (%d)", instructionOpcodeName(opcode), count))
		}
	}
	if policy.RequireBoundedLoops && len(analysis.LoopBoundFailures) > 0 {
		for _, failure := range analysis.LoopBoundFailures {
			failures = append(failures, fmt.Sprintf("loop bound not proven: function %d loop %d: %s", failure.Function, failure.Loop, failure.Reason))
		}
	}

	if len(failures) > 0 {
		return errors.New(strings.Join(failures, "; "))
	}
	return nil
}

func instructionOpcodeName(opcode InstructionOpcode) string {
	if name, ok := instructionOpcodeNames[opcode]; ok {
		return name
	}
	return fmt.Sprintf("opcode 0x%x", uint32(opcode))
}

func pagesToBytes(pages uint64) (uint64, bool) {
	if pages > ^uint64(0)/WasmPageSizeBytes {
		return 0, false
	}
	return pages * WasmPageSizeBytes, true
}

func appendTrace(recent []instrTrace, instr instrTrace) []instrTrace {
	const maxRecent = 8
	recent = append(recent, instr)
	if len(recent) > maxRecent {
		copy(recent, recent[len(recent)-maxRecent:])
		recent = recent[:maxRecent]
	}
	return recent
}

func traceLocalGet(t instrTrace) (uint32, bool) {
	if t.op != 0x20 || !t.hasImm || t.imm < 0 {
		return 0, false
	}
	return uint32(t.imm), true
}

func traceI32Const(t instrTrace) (int32, bool) {
	if t.op != 0x41 || !t.hasImm {
		return 0, false
	}
	return int32(t.imm), true
}

func detectCounterUpdate(recent []instrTrace, setLocal uint32) (loopCounterDirection, bool) {
	if len(recent) < 3 {
		return 0, false
	}
	a := recent[len(recent)-3]
	b := recent[len(recent)-2]
	op := recent[len(recent)-1]

	if op.op != 0x6a && op.op != 0x6b { // i32.add, i32.sub
		return 0, false
	}

	if local, ok := traceLocalGet(a); ok && local == setLocal {
		if delta, ok := traceI32Const(b); ok {
			return counterDirection(op.op, delta)
		}
	}
	if op.op == 0x6a {
		if delta, ok := traceI32Const(a); ok {
			if local, ok := traceLocalGet(b); ok && local == setLocal {
				return counterDirection(op.op, delta)
			}
		}
	}
	return 0, false
}

func counterDirection(op byte, delta int32) (loopCounterDirection, bool) {
	if delta == 0 {
		return 0, false
	}
	switch op {
	case 0x6a: // i32.add
		if delta > 0 {
			return loopCounterInc, true
		}
		return loopCounterDec, true
	case 0x6b: // i32.sub
		if delta > 0 {
			return loopCounterDec, true
		}
		return loopCounterInc, true
	default:
		return 0, false
	}
}

func isI32Compare(op byte) bool {
	switch op {
	case 0x46, 0x47, 0x48, 0x49, 0x4b, 0x4d, 0x4f:
		return true
	default:
		return false
	}
}

func detectBoundCandidates(recent []instrTrace, branchBack bool) []boundCandidate {
	if len(recent) < 2 {
		return nil
	}
	last := recent[len(recent)-1]
	prev := recent[len(recent)-2]
	if last.op == 0x45 { // i32.eqz
		if branchBack {
			return nil
		}
		if local, ok := traceLocalGet(prev); ok {
			return []boundCandidate{{local: local, direction: loopCounterDec}}
		}
	}
	if !isI32Compare(last.op) {
		return nil
	}

	if len(recent) >= 3 {
		leftLocal, leftLocalOK := traceLocalGet(recent[len(recent)-3])
		rightLocal, rightLocalOK := traceLocalGet(recent[len(recent)-2])
		if leftLocalOK && rightLocalOK {
			return compareBoundCandidates(last.op, leftLocal, rightLocal, branchBack)
		}
		if leftLocalOK {
			if _, ok := traceI32Const(recent[len(recent)-2]); ok {
				return compareLocalConstBoundCandidates(last.op, leftLocal, false, branchBack)
			}
		}
		if rightLocalOK {
			if _, ok := traceI32Const(recent[len(recent)-3]); ok {
				return compareLocalConstBoundCandidates(last.op, rightLocal, true, branchBack)
			}
		}
	}

	// Common bottom-tested shape after an update:
	// local.get bound; local.get i; i32.const 1; i32.add; local.tee i; i32.ne
	if len(recent) >= 6 && recent[len(recent)-2].op == 0x22 {
		local := uint32(recent[len(recent)-2].imm)
		if _, ok := traceLocalGet(recent[len(recent)-6]); ok {
			if dir, ok := detectCounterUpdate(recent[:len(recent)-2], local); ok {
				return []boundCandidate{{local: local, direction: dir}}
			}
		}
	}
	// Equivalent bottom-tested shape with the updated counter on the left:
	// local.get i; i32.const -1; i32.add; local.tee i; local.get bound; i32.gt_u
	if len(recent) >= 6 && recent[len(recent)-3].op == 0x22 {
		local := uint32(recent[len(recent)-3].imm)
		if _, ok := traceLocalGet(recent[len(recent)-2]); ok {
			if dir, ok := detectCounterUpdate(recent[:len(recent)-3], local); ok {
				return []boundCandidate{{local: local, direction: dir}}
			}
		}
	}
	return nil
}

func compareLocalConstBoundCandidates(op byte, local uint32, localOnRight bool, branchBack bool) []boundCandidate {
	if localOnRight {
		switch op {
		case 0x46, 0x47: // i32.eq, i32.ne
			return []boundCandidate{{local: local, direction: loopCounterInc | loopCounterDec}}
		case 0x4f, 0x4b: // const >= local, const > local
			return []boundCandidate{{local: local, direction: chooseBoundDirection(loopCounterDec, branchBack)}}
		case 0x4d, 0x49: // const <= local, const < local
			return []boundCandidate{{local: local, direction: chooseBoundDirection(loopCounterInc, branchBack)}}
		default:
			return nil
		}
	}
	switch op {
	case 0x46, 0x47: // i32.eq, i32.ne
		return []boundCandidate{{local: local, direction: loopCounterInc | loopCounterDec}}
	case 0x4f, 0x4b: // local >= const, local > const
		return []boundCandidate{{local: local, direction: chooseBoundDirection(loopCounterInc, branchBack)}}
	case 0x4d, 0x49: // local <= const, local < const
		return []boundCandidate{{local: local, direction: chooseBoundDirection(loopCounterDec, branchBack)}}
	default:
		return nil
	}
}

func compareBoundCandidates(op byte, left uint32, right uint32, branchBack bool) []boundCandidate {
	switch op {
	case 0x46, 0x47: // i32.eq, i32.ne
		return []boundCandidate{
			{local: left, direction: loopCounterInc | loopCounterDec},
			{local: right, direction: loopCounterInc | loopCounterDec},
		}
	case 0x4f, 0x4b: // i32.ge_u, i32.gt_u
		return []boundCandidate{
			{local: left, direction: chooseBoundDirection(loopCounterInc, branchBack)},
			{local: right, direction: chooseBoundDirection(loopCounterDec, branchBack)},
		}
	case 0x4d, 0x49: // i32.le_u, i32.lt_u
		return []boundCandidate{
			{local: left, direction: chooseBoundDirection(loopCounterDec, branchBack)},
			{local: right, direction: chooseBoundDirection(loopCounterInc, branchBack)},
		}
	default:
		return nil
	}
}

func chooseBoundDirection(exitDirection loopCounterDirection, branchBack bool) loopCounterDirection {
	if !branchBack {
		return exitDirection
	}
	switch exitDirection {
	case loopCounterInc:
		return loopCounterDec
	case loopCounterDec:
		return loopCounterInc
	default:
		return exitDirection
	}
}

func markLoopCounterUpdate(loops []loopEvidence, controlStack []controlFrame, local uint32, direction loopCounterDirection) {
	if direction == 0 {
		return
	}
	for _, frame := range controlStack {
		if frame.op != 0x03 || frame.loopIdx < 0 || frame.loopIdx >= len(loops) {
			continue
		}
		loop := &loops[frame.loopIdx]
		if loop.counters == nil {
			loop.counters = map[uint32]loopCounterEvidence{}
		}
		evidence := loop.counters[local]
		evidence.update |= direction
		loop.counters[local] = evidence
	}
}

func markLoopCounterExit(loop *loopEvidence, candidate boundCandidate) {
	if candidate.direction == 0 {
		return
	}
	if loop.counters == nil {
		loop.counters = map[uint32]loopCounterEvidence{}
	}
	evidence := loop.counters[candidate.local]
	evidence.exit |= candidate.direction
	loop.counters[candidate.local] = evidence
}

func loopHasBoundedCounter(loop loopEvidence) bool {
	for _, evidence := range loop.counters {
		if evidence.update&evidence.exit != 0 {
			return true
		}
	}
	return false
}

func DetectCallCycle(edges []map[int]struct{}) (bool, []int) {
	return detectCallCycle(edges)
}

func EvaluateQIPContractChecks(analysis Analysis) ([]ContractCheck, bool) {
	return evaluateContractChecks(
		analysis.Exports,
		analysis.ImportedFuncCount,
		analysis.FuncMetrics,
		analysis.ImportedGlobals,
		analysis.GlobalMetrics,
	)
}

func evaluateContractChecks(
	exports map[string]wasmExport,
	importedFuncCount int,
	fnMetrics []functionMetrics,
	importedGlobals int,
	globalMetrics []globalInitMetrics,
) ([]contractCheck, bool) {
	checks := make([]contractCheck, 0, len(qipContractExports))
	fail := false

	for _, name := range qipContractExports {
		exp, ok := exports[name]
		if !ok {
			continue
		}
		switch exp.kind {
		case 0x00: // function
			globalIdx := int(exp.index)
			if globalIdx < importedFuncCount {
				checks = append(checks, contractCheck{Export: name, Kind: "func", Pass: false, Reason: "imported function"})
				fail = true
				continue
			}
			defIdx := globalIdx - importedFuncCount
			if defIdx < 0 || defIdx >= len(fnMetrics) {
				checks = append(checks, contractCheck{Export: name, Kind: "func", Pass: false, Reason: "function index out of range"})
				fail = true
				continue
			}
			fm := fnMetrics[defIdx]
			reasons := make([]string, 0, 4)
			if fm.CallLocal+fm.CallImport+fm.CallIndirect > 0 {
				reasons = append(reasons, "contains call")
			}
			if fm.LoopBackedge > 0 {
				reasons = append(reasons, "contains loop")
			}
			if fm.BranchDecision > 0 || fm.BrTableCount > 0 || fm.ControlFlowOps > 0 {
				reasons = append(reasons, "contains branch/control flow")
			}
			if fm.LocalOps > 0 {
				reasons = append(reasons, "contains local ops")
			}
			if fm.MemoryOps > 0 || fm.TableOps > 0 {
				reasons = append(reasons, "contains memory/table ops")
			}
			if len(reasons) > 0 {
				checks = append(checks, contractCheck{Export: name, Kind: "func", Pass: false, Reason: strings.Join(reasons, ", ")})
				fail = true
			} else {
				checks = append(checks, contractCheck{Export: name, Kind: "func", Pass: true})
			}
		case 0x03: // global
			globalIdx := int(exp.index)
			if globalIdx < importedGlobals {
				checks = append(checks, contractCheck{Export: name, Kind: "global", Pass: false, Reason: "imported global"})
				fail = true
				continue
			}
			defIdx := globalIdx - importedGlobals
			if defIdx < 0 || defIdx >= len(globalMetrics) {
				checks = append(checks, contractCheck{Export: name, Kind: "global", Pass: false, Reason: "global index out of range"})
				fail = true
				continue
			}
			gm := globalMetrics[defIdx]
			reasons := make([]string, 0, 3)
			if gm.InstructionTotal == 0 {
				reasons = append(reasons, "empty init expr")
			}
			if gm.HasGlobalGet {
				reasons = append(reasons, "depends on global.get")
			}
			if !gm.SimpleConst {
				reasons = append(reasons, "non-constant init expr")
			}
			if len(reasons) > 0 {
				checks = append(checks, contractCheck{Export: name, Kind: "global", Pass: false, Reason: strings.Join(reasons, ", ")})
				fail = true
			} else {
				checks = append(checks, contractCheck{Export: name, Kind: "global", Pass: true})
			}
		default:
			checks = append(checks, contractCheck{Export: name, Kind: fmt.Sprintf("kind=%d", exp.kind), Pass: false, Reason: "unsupported export kind"})
			fail = true
		}
	}

	return checks, fail
}

type wasmReader struct {
	data []byte
	off  int
}

func newWasmReader(data []byte) *wasmReader {
	return &wasmReader{data: data}
}

func (r *wasmReader) remaining() int {
	return len(r.data) - r.off
}

func (r *wasmReader) offset() int {
	return r.off
}

func (r *wasmReader) readByte() (byte, error) {
	if r.off >= len(r.data) {
		return 0, io.ErrUnexpectedEOF
	}
	b := r.data[r.off]
	r.off++
	return b, nil
}

func (r *wasmReader) peekByte() (byte, error) {
	if r.off >= len(r.data) {
		return 0, io.ErrUnexpectedEOF
	}
	return r.data[r.off], nil
}

func (r *wasmReader) readN(n int) ([]byte, error) {
	if n < 0 || r.remaining() < n {
		return nil, io.ErrUnexpectedEOF
	}
	start := r.off
	r.off += n
	return r.data[start:r.off], nil
}

func (r *wasmReader) readVarU32() (uint32, error) {
	var result uint32
	var shift uint
	for range 5 {
		b, err := r.readByte()
		if err != nil {
			return 0, err
		}
		result |= uint32(b&0x7f) << shift
		if b&0x80 == 0 {
			return result, nil
		}
		shift += 7
	}
	return 0, errors.New("invalid u32 leb128")
}

func (r *wasmReader) readVarU64() (uint64, error) {
	var result uint64
	var shift uint
	for range 10 {
		b, err := r.readByte()
		if err != nil {
			return 0, err
		}
		result |= uint64(b&0x7f) << shift
		if b&0x80 == 0 {
			return result, nil
		}
		shift += 7
	}
	return 0, errors.New("invalid u64 leb128")
}

func (r *wasmReader) readVarS32() (int32, error) {
	var result int32
	var shift uint
	var b byte
	for i := range 5 {
		var err error
		b, err = r.readByte()
		if err != nil {
			return 0, err
		}
		result |= int32(b&0x7f) << shift
		shift += 7
		if b&0x80 == 0 {
			break
		}
		if i == 4 {
			return 0, errors.New("invalid s32 leb128")
		}
	}
	if shift < 32 && (b&0x40) != 0 {
		result |= ^int32(0) << shift
	}
	return result, nil
}

func (r *wasmReader) readVarS64(maxBytes int) (int64, error) {
	var result int64
	var shift uint
	var b byte
	for i := range maxBytes {
		var err error
		b, err = r.readByte()
		if err != nil {
			return 0, err
		}
		result |= int64(b&0x7f) << shift
		shift += 7
		if b&0x80 == 0 {
			break
		}
		if i == maxBytes-1 {
			return 0, errors.New("invalid s64 leb128")
		}
	}
	if shift < 64 && (b&0x40) != 0 {
		result |= ^int64(0) << shift
	}
	return result, nil
}

func (r *wasmReader) readName() (string, error) {
	n, err := r.readVarU32()
	if err != nil {
		return "", err
	}
	b, err := r.readN(int(n))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func analyzeWASMModule(wasm []byte) (wasmAnalysis, error) {
	if len(wasm) < 8 {
		return wasmAnalysis{}, errors.New("invalid wasm: file too small")
	}
	if string(wasm[0:4]) != "\x00asm" {
		return wasmAnalysis{}, errors.New("invalid wasm: bad magic")
	}
	if wasm[4] != 0x01 || wasm[5] != 0x00 || wasm[6] != 0x00 || wasm[7] != 0x00 {
		return wasmAnalysis{}, errors.New("invalid wasm: unsupported version")
	}

	r := newWasmReader(wasm[8:])
	var imports importCounts
	var functionTypeIdx []uint32
	analysis := wasmAnalysis{
		InstructionCounts: map[InstructionOpcode]int{},
		Exports:           map[string]wasmExport{},
	}
	startFuncIdx := -1

	for r.remaining() > 0 {
		sectionID, err := r.readByte()
		if err != nil {
			return wasmAnalysis{}, fmt.Errorf("read section id at offset %d: %w", r.offset()+8, err)
		}
		sectionSize, err := r.readVarU32()
		if err != nil {
			return wasmAnalysis{}, fmt.Errorf("read section size at offset %d: %w", r.offset()+8, err)
		}
		payload, err := r.readN(int(sectionSize))
		if err != nil {
			return wasmAnalysis{}, fmt.Errorf("read section payload id=%d at offset %d: %w", sectionID, r.offset()+8, err)
		}

		switch sectionID {
		case 0:
			// custom section
		case 1:
			if err := parseTypeSection(payload); err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse type section: %w", err)
			}
		case 2:
			counts, err := parseImportSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse import section: %w", err)
			}
			imports = counts
			analysis.MemoryLimits = append(analysis.MemoryLimits, counts.MemoryLimits...)
			for _, memory := range counts.MemoryLimits {
				analysis.Instantiation.MemoryMinPages += memory.MinPages
			}
		case 3:
			idxs, err := parseFunctionSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse function section: %w", err)
			}
			functionTypeIdx = idxs
		case 4:
			min, err := parseTableSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse table section: %w", err)
			}
			analysis.Instantiation.TableMinElements = min
		case 5:
			memories, err := parseMemorySection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse memory section: %w", err)
			}
			analysis.MemoryLimits = append(analysis.MemoryLimits, memories...)
			for _, memory := range memories {
				analysis.Instantiation.MemoryMinPages += memory.MinPages
			}
		case 6:
			globals, err := parseGlobalSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse global section: %w", err)
			}
			analysis.GlobalMetrics = globals
		case 7:
			exports, err := parseExportSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse export section: %w", err)
			}
			analysis.Exports = exports
		case 8:
			startIdx, hasStart, err := parseStartSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse start section: %w", err)
			}
			if hasStart {
				startFuncIdx = int(startIdx)
				analysis.Instantiation.HasStart = true
			}
		case 10:
			edges, fnMetrics, loopFailures, err := parseCodeSection(payload, imports.Funcs, len(functionTypeIdx), &analysis.Metrics, analysis.InstructionCounts)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse code section: %w", err)
			}
			analysis.CallEdges = edges
			analysis.FuncMetrics = fnMetrics
			analysis.LoopBoundFailures = append(analysis.LoopBoundFailures, loopFailures...)
		case 9:
			segCount, elemCount, err := parseElementSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse element section: %w", err)
			}
			analysis.Instantiation.ActiveElemSegments = segCount
			analysis.Instantiation.ActiveElemElements = elemCount
		case 11:
			segCount, byteCount, err := parseDataSection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse data section: %w", err)
			}
			analysis.Instantiation.ActiveDataSegments = segCount
			analysis.Instantiation.ActiveDataBytes = byteCount
		}
	}

	analysis.ImportedFuncCount = imports.Funcs
	analysis.ImportedGlobals = imports.Globals

	if len(functionTypeIdx) != 0 && analysis.CallEdges == nil {
		return wasmAnalysis{}, errors.New("invalid wasm: function section without code section")
	}
	if analysis.CallEdges == nil {
		analysis.CallEdges = make([]map[int]struct{}, 0)
		analysis.FuncMetrics = make([]functionMetrics, 0)
	}
	if startFuncIdx >= 0 {
		if startFuncIdx >= imports.Funcs {
			defIdx := startFuncIdx - imports.Funcs
			if defIdx >= 0 && defIdx < len(analysis.FuncMetrics) {
				fm := analysis.FuncMetrics[defIdx]
				analysis.Instantiation.StartInstructionCnt = fm.InstructionTotal
				analysis.Instantiation.StartCalls = fm.CallLocal + fm.CallImport + fm.CallIndirect
				analysis.Instantiation.StartBranches = fm.BranchDecision + fm.BrTableCount + fm.ControlFlowOps
				analysis.Instantiation.StartLoopBackedges = fm.LoopBackedge
			}
		}
	}

	return analysis, nil
}

func parseTypeSection(payload []byte) error {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return err
	}
	for i := 0; i < int(n); i++ {
		form, err := r.readByte()
		if err != nil {
			return err
		}
		if form != 0x60 {
			return fmt.Errorf("unsupported type form 0x%x", form)
		}
		params, err := r.readVarU32()
		if err != nil {
			return err
		}
		if _, err := r.readN(int(params)); err != nil {
			return err
		}
		results, err := r.readVarU32()
		if err != nil {
			return err
		}
		if _, err := r.readN(int(results)); err != nil {
			return err
		}
	}
	if r.remaining() != 0 {
		return errors.New("trailing bytes in type section")
	}
	return nil
}

func parseImportSection(payload []byte) (importCounts, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return importCounts{}, err
	}
	counts := importCounts{}
	for i := 0; i < int(n); i++ {
		if _, err := r.readName(); err != nil {
			return importCounts{}, err
		}
		if _, err := r.readName(); err != nil {
			return importCounts{}, err
		}
		kind, err := r.readByte()
		if err != nil {
			return importCounts{}, err
		}
		switch kind {
		case 0x00: // func
			if _, err := r.readVarU32(); err != nil {
				return importCounts{}, err
			}
			counts.Funcs++
		case 0x01: // table
			if err := skipTableType(r); err != nil {
				return importCounts{}, err
			}
		case 0x02: // memory
			limit, err := parseLimits(r)
			if err != nil {
				return importCounts{}, err
			}
			limit.Imported = true
			counts.MemoryLimits = append(counts.MemoryLimits, limit)
		case 0x03: // global
			if err := skipGlobalType(r); err != nil {
				return importCounts{}, err
			}
			counts.Globals++
		case 0x04: // tag
			if _, err := r.readByte(); err != nil {
				return importCounts{}, err
			}
			if _, err := r.readVarU32(); err != nil {
				return importCounts{}, err
			}
		default:
			return importCounts{}, fmt.Errorf("unsupported import kind 0x%x", kind)
		}
	}
	if r.remaining() != 0 {
		return importCounts{}, errors.New("trailing bytes in import section")
	}
	return counts, nil
}

func parseFunctionSection(payload []byte) ([]uint32, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	idxs := make([]uint32, 0, n)
	for i := 0; i < int(n); i++ {
		v, err := r.readVarU32()
		if err != nil {
			return nil, err
		}
		idxs = append(idxs, v)
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in function section")
	}
	return idxs, nil
}

func parseGlobalSection(payload []byte) ([]globalInitMetrics, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	globals := make([]globalInitMetrics, 0, n)
	for i := 0; i < int(n); i++ {
		if err := skipGlobalType(r); err != nil {
			return nil, err
		}
		gm, err := parseGlobalInitExpr(r)
		if err != nil {
			return nil, err
		}
		globals = append(globals, gm)
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in global section")
	}
	return globals, nil
}

func parseExportSection(payload []byte) (map[string]wasmExport, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	exports := make(map[string]wasmExport, n)
	for i := 0; i < int(n); i++ {
		name, err := r.readName()
		if err != nil {
			return nil, err
		}
		kind, err := r.readByte()
		if err != nil {
			return nil, err
		}
		idx, err := r.readVarU32()
		if err != nil {
			return nil, err
		}
		exports[name] = wasmExport{kind: kind, index: idx}
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in export section")
	}
	return exports, nil
}

func parseStartSection(payload []byte) (uint32, bool, error) {
	r := newWasmReader(payload)
	idx, err := r.readVarU32()
	if err != nil {
		return 0, false, err
	}
	if r.remaining() != 0 {
		return 0, false, errors.New("trailing bytes in start section")
	}
	return idx, true, nil
}

func parseMemorySection(payload []byte) ([]memoryLimit, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	memories := make([]memoryLimit, 0, n)
	for i := 0; i < int(n); i++ {
		limit, err := parseLimits(r)
		if err != nil {
			return nil, err
		}
		memories = append(memories, limit)
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in memory section")
	}
	return memories, nil
}

func parseTableSection(payload []byte) (uint64, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return 0, err
	}
	var minElems uint64
	for i := 0; i < int(n); i++ {
		if _, err := r.readByte(); err != nil { // reftype
			return 0, err
		}
		min, err := parseLimitsMin(r)
		if err != nil {
			return 0, err
		}
		minElems += min
	}
	if r.remaining() != 0 {
		return 0, errors.New("trailing bytes in table section")
	}
	return minElems, nil
}

func parseDataSection(payload []byte) (int, uint64, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return 0, 0, err
	}
	segments := 0
	var bytes uint64
	for i := 0; i < int(n); i++ {
		flags, err := r.readVarU32()
		if err != nil {
			return 0, 0, err
		}
		active := false
		switch flags {
		case 0:
			active = true
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
		case 1:
			// passive
		case 2:
			active = true
			if _, err := r.readVarU32(); err != nil { // memidx
				return 0, 0, err
			}
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
		default:
			return 0, 0, fmt.Errorf("unsupported data segment flags %d", flags)
		}
		size, err := r.readVarU32()
		if err != nil {
			return 0, 0, err
		}
		if _, err := r.readN(int(size)); err != nil {
			return 0, 0, err
		}
		if active {
			segments++
			bytes += uint64(size)
		}
	}
	if r.remaining() != 0 {
		return 0, 0, errors.New("trailing bytes in data section")
	}
	return segments, bytes, nil
}

func parseElementSection(payload []byte) (int, uint64, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return 0, 0, err
	}
	activeSegments := 0
	var activeElems uint64
	for i := 0; i < int(n); i++ {
		flags, err := r.readVarU32()
		if err != nil {
			return 0, 0, err
		}

		active := false
		exprElems := false
		switch flags {
		case 0:
			active = true
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
		case 1:
			if _, err := r.readByte(); err != nil { // elemkind
				return 0, 0, err
			}
		case 2:
			active = true
			if _, err := r.readVarU32(); err != nil { // tableidx
				return 0, 0, err
			}
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
			if _, err := r.readByte(); err != nil { // elemkind
				return 0, 0, err
			}
		case 3:
			if _, err := r.readByte(); err != nil { // elemkind
				return 0, 0, err
			}
		case 4:
			active = true
			exprElems = true
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
		case 5:
			exprElems = true
			if _, err := r.readByte(); err != nil { // reftype
				return 0, 0, err
			}
		case 6:
			active = true
			exprElems = true
			if _, err := r.readVarU32(); err != nil { // tableidx
				return 0, 0, err
			}
			if err := skipConstExpr(r); err != nil {
				return 0, 0, err
			}
			if _, err := r.readByte(); err != nil { // reftype
				return 0, 0, err
			}
		case 7:
			exprElems = true
			if _, err := r.readByte(); err != nil { // reftype
				return 0, 0, err
			}
		default:
			return 0, 0, fmt.Errorf("unsupported element segment flags %d", flags)
		}

		elemCount, err := r.readVarU32()
		if err != nil {
			return 0, 0, err
		}
		if exprElems {
			for j := 0; j < int(elemCount); j++ {
				if err := skipConstExpr(r); err != nil {
					return 0, 0, err
				}
			}
		} else {
			for j := 0; j < int(elemCount); j++ {
				if _, err := r.readVarU32(); err != nil {
					return 0, 0, err
				}
			}
		}
		if active {
			activeSegments++
			activeElems += uint64(elemCount)
		}
	}
	if r.remaining() != 0 {
		return 0, 0, errors.New("trailing bytes in element section")
	}
	return activeSegments, activeElems, nil
}

func parseCodeSection(
	payload []byte,
	importedFuncCount int,
	definedFuncCount int,
	metrics *scoreMetrics,
	instructionCounts map[InstructionOpcode]int,
) ([]map[int]struct{}, []functionMetrics, []LoopBoundFailure, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, nil, nil, err
	}
	if int(n) != definedFuncCount {
		return nil, nil, nil, fmt.Errorf("function/code count mismatch: function=%d code=%d", definedFuncCount, n)
	}
	edges := make([]map[int]struct{}, definedFuncCount)
	funcMetrics := make([]functionMetrics, definedFuncCount)
	loopFailures := make([]LoopBoundFailure, 0)
	for i := 0; i < int(n); i++ {
		bodySize, err := r.readVarU32()
		if err != nil {
			return nil, nil, nil, err
		}
		body, err := r.readN(int(bodySize))
		if err != nil {
			return nil, nil, nil, err
		}
		fm, failures, err := parseFunctionBody(body, i, importedFuncCount, definedFuncCount, metrics, instructionCounts, edges)
		if err != nil {
			return nil, nil, nil, fmt.Errorf("function %d: %w", i, err)
		}
		funcMetrics[i] = fm
		loopFailures = append(loopFailures, failures...)
	}
	if r.remaining() != 0 {
		return nil, nil, nil, errors.New("trailing bytes in code section")
	}
	return edges, funcMetrics, loopFailures, nil
}

func parseFunctionBody(
	body []byte,
	funcIdx int,
	importedFuncCount int,
	definedFuncCount int,
	metrics *scoreMetrics,
	instructionCounts map[InstructionOpcode]int,
	edges []map[int]struct{},
) (functionMetrics, []LoopBoundFailure, error) {
	r := newWasmReader(body)
	localDecls, err := r.readVarU32()
	if err != nil {
		return functionMetrics{}, nil, err
	}
	for i := 0; i < int(localDecls); i++ {
		if _, err := r.readVarU32(); err != nil {
			return functionMetrics{}, nil, err
		}
		if _, err := r.readByte(); err != nil {
			return functionMetrics{}, nil, err
		}
	}

	const (
		opBlock = 0x02
		opLoop  = 0x03
		opIf    = 0x04
		opElse  = 0x05
		opEnd   = 0x0b
	)

	fm := functionMetrics{}
	controlStack := make([]controlFrame, 0, 16)
	loops := make([]loopEvidence, 0, 8)
	loopFailures := make([]LoopBoundFailure, 0)
	recent := make([]instrTrace, 0, 8)

	addInstr := func() {
		metrics.InstructionTotal++
		fm.InstructionTotal++
	}
	addLoop := func() int {
		metrics.LoopCount++
		fm.LoopCount++
		idx := len(loops)
		loops = append(loops, loopEvidence{index: fm.LoopCount})
		return idx
	}
	addBranch := func() {
		metrics.BranchDecision++
		fm.BranchDecision++
	}
	addBrTable := func(targets int) {
		metrics.BrTableCount++
		metrics.BrTableTargets += targets
		fm.BrTableCount++
		fm.BrTableTargets += targets
	}
	addLoopBack := func() {
		metrics.LoopBackedge++
		fm.LoopBackedge++
	}
	addCallImport := func() {
		metrics.CallImport++
		fm.CallImport++
	}
	addCallLocal := func() {
		metrics.CallLocal++
		fm.CallLocal++
	}
	addCallIndirect := func() {
		metrics.CallIndirect++
		fm.CallIndirect++
	}

	for {
		op, err := r.readByte()
		if err != nil {
			return functionMetrics{}, nil, err
		}
		addInstr()
		trace := instrTrace{op: op}

		switch op {
		case 0x00, 0x01, opElse, 0x0f, 0x1a, 0x1b:
			// no immediate
			if op == 0x1b {
				fm.ControlFlowOps++
			}
		case opBlock, opLoop, opIf:
			if err := readBlockType(r); err != nil {
				return functionMetrics{}, nil, err
			}
			if op == opIf {
				addBranch()
			} else {
				fm.ControlFlowOps++
			}
			loopIdx := -1
			if op == opLoop {
				loopIdx = addLoop()
			}
			controlStack = append(controlStack, controlFrame{op: op, loopIdx: loopIdx})
		case opEnd:
			if len(controlStack) == 0 {
				if r.remaining() != 0 {
					return functionMetrics{}, nil, errors.New("trailing bytes after final end")
				}
				return fm, loopFailures, nil
			}
			frame := controlStack[len(controlStack)-1]
			controlStack = controlStack[:len(controlStack)-1]
			if frame.op == opLoop && frame.loopIdx >= 0 && frame.loopIdx < len(loops) {
				loop := loops[frame.loopIdx]
				if loop.hasBackedge && !loopHasBoundedCounter(loop) {
					loopFailures = append(loopFailures, LoopBoundFailure{
						Function: funcIdx,
						Loop:     loop.index,
						Reason:   "no local counter with a matching monotonic update and exit bound",
					})
				}
			}
		case 0x0c:
			depth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(depth)
			trace.hasImm = true
			fm.ControlFlowOps++
			if isLoopTarget(controlStack, depth) {
				addLoopBack()
			}
			markBranchLoopEvidence(loops, controlStack, depth, nil, nil)
		case 0x0d:
			depth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(depth)
			trace.hasImm = true
			addBranch()
			exitCandidates := detectBoundCandidates(recent, false)
			continueCandidates := detectBoundCandidates(recent, true)
			if isLoopTarget(controlStack, depth) {
				addLoopBack()
			}
			markBranchLoopEvidence(loops, controlStack, depth, exitCandidates, continueCandidates)
		case 0x0e:
			targetCount, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(targetCount)
			trace.hasImm = true
			addBrTable(int(targetCount))
			exitCandidates := detectBoundCandidates(recent, false)
			continueCandidates := detectBoundCandidates(recent, true)
			hasLoopTarget := false
			for i := 0; i < int(targetCount); i++ {
				depth, err := r.readVarU32()
				if err != nil {
					return functionMetrics{}, nil, err
				}
				if isLoopTarget(controlStack, depth) {
					hasLoopTarget = true
				}
				markBranchLoopEvidence(loops, controlStack, depth, exitCandidates, continueCandidates)
			}
			defaultDepth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			if isLoopTarget(controlStack, defaultDepth) {
				hasLoopTarget = true
			}
			markBranchLoopEvidence(loops, controlStack, defaultDepth, exitCandidates, continueCandidates)
			if hasLoopTarget {
				addLoopBack()
			}
		case 0x10, 0x12:
			idx, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(idx)
			trace.hasImm = true
			if int(idx) < importedFuncCount {
				addCallImport()
			} else {
				addCallLocal()
				callee := int(idx) - importedFuncCount
				if callee >= 0 && callee < definedFuncCount {
					if edges[funcIdx] == nil {
						edges[funcIdx] = map[int]struct{}{}
					}
					edges[funcIdx][callee] = struct{}{}
				}
			}
		case 0x11, 0x13:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
			addCallIndirect()
			fm.TableOps++
		case 0x14:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
			addCallIndirect()
		case 0x1c:
			count, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			if _, err := r.readN(int(count)); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26:
			idx, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(idx)
			trace.hasImm = true
			switch op {
			case 0x23:
				// global.get is the expected shape for qip contract accessor functions.
			case 0x25, 0x26:
				fm.TableOps++
			default:
				fm.LocalOps++
			}
			if op == 0x21 || op == 0x22 {
				if dir, ok := detectCounterUpdate(recent, idx); ok {
					markLoopCounterUpdate(loops, controlStack, idx, dir)
				}
			}
		case 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
			0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
			0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e:
			if err := readMemArg(r); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		case 0x3f, 0x40:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
			if op == 0x40 {
				instructionCounts[OpcodeMemoryGrow]++
			}
			fm.MemoryOps++
		case 0x41:
			v, err := r.readVarS32()
			if err != nil {
				return functionMetrics{}, nil, err
			}
			trace.imm = int64(v)
			trace.hasImm = true
		case 0x42:
			if _, err := r.readVarS64(10); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0x43:
			if _, err := r.readN(4); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0x44:
			if _, err := r.readN(8); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0xd0:
			if _, err := r.readByte(); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0xd2:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, nil, err
			}
		case 0xfc:
			if err := readFCImmediate(r); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		case 0xfd:
			if err := readFDImmediate(r); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		case 0xfe:
			if err := readFEImmediate(r); err != nil {
				return functionMetrics{}, nil, err
			}
			fm.MemoryOps++
		default:
			// Most core numeric/reference ops have no immediates.
		}
		recent = appendTrace(recent, trace)
	}
}

func parseGlobalInitExpr(r *wasmReader) (globalInitMetrics, error) {
	instr := 0
	simpleConst := false
	hasGlobalGet := false
	for {
		op, err := r.readByte()
		if err != nil {
			return globalInitMetrics{}, err
		}
		if op == 0x0b {
			break
		}
		instr++
		switch op {
		case 0x41:
			if _, err := r.readVarS32(); err != nil {
				return globalInitMetrics{}, err
			}
		case 0x42:
			if _, err := r.readVarS64(10); err != nil {
				return globalInitMetrics{}, err
			}
		case 0x43:
			if _, err := r.readN(4); err != nil {
				return globalInitMetrics{}, err
			}
		case 0x44:
			if _, err := r.readN(8); err != nil {
				return globalInitMetrics{}, err
			}
		case 0xd0:
			if _, err := r.readByte(); err != nil {
				return globalInitMetrics{}, err
			}
		case 0xd2:
			if _, err := r.readVarU32(); err != nil {
				return globalInitMetrics{}, err
			}
		case 0x23:
			if _, err := r.readVarU32(); err != nil {
				return globalInitMetrics{}, err
			}
			hasGlobalGet = true
		default:
			return globalInitMetrics{}, fmt.Errorf("unsupported const expr opcode 0x%x", op)
		}
	}
	if instr == 1 && !hasGlobalGet {
		simpleConst = true
	}
	return globalInitMetrics{
		InstructionTotal: instr,
		SimpleConst:      simpleConst,
		HasGlobalGet:     hasGlobalGet,
	}, nil
}

func skipConstExpr(r *wasmReader) error {
	for {
		op, err := r.readByte()
		if err != nil {
			return err
		}
		if op == 0x0b {
			return nil
		}
		switch op {
		case 0x41:
			if _, err := r.readVarS32(); err != nil {
				return err
			}
		case 0x42:
			if _, err := r.readVarS64(10); err != nil {
				return err
			}
		case 0x43:
			if _, err := r.readN(4); err != nil {
				return err
			}
		case 0x44:
			if _, err := r.readN(8); err != nil {
				return err
			}
		case 0xd0:
			if _, err := r.readByte(); err != nil {
				return err
			}
		case 0xd2, 0x23:
			if _, err := r.readVarU32(); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unsupported const expr opcode 0x%x", op)
		}
	}
}

func readBlockType(r *wasmReader) error {
	b, err := r.peekByte()
	if err != nil {
		return err
	}
	switch b {
	case 0x40, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x70, 0x6f:
		_, err := r.readByte()
		return err
	default:
		_, err := r.readVarS64(5)
		return err
	}
}

func readMemArg(r *wasmReader) error {
	if _, err := r.readVarU32(); err != nil {
		return err
	}
	if _, err := r.readVarU32(); err != nil {
		return err
	}
	return nil
}

func readFCImmediate(r *wasmReader) error {
	sub, err := r.readVarU32()
	if err != nil {
		return err
	}
	switch sub {
	case 8: // memory.init
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 9: // data.drop
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 10: // memory.copy
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 11: // memory.fill
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 12: // table.init
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 13: // elem.drop
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 14: // table.copy
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 15, 16, 17: // table.grow/size/fill
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	default:
		// Other FC opcodes used by current modules have no immediates.
	}
	return nil
}

func readFDImmediate(r *wasmReader) error {
	sub, err := r.readVarU32()
	if err != nil {
		return err
	}
	switch {
	case sub <= 11:
		return readMemArg(r)
	case sub == 12:
		_, err := r.readN(16)
		return err
	case sub == 13:
		_, err := r.readN(16)
		return err
	case sub >= 21 && sub <= 34:
		_, err := r.readByte()
		return err
	case sub >= 84 && sub <= 91:
		if err := readMemArg(r); err != nil {
			return err
		}
		_, err := r.readByte()
		return err
	case sub == 92 || sub == 93:
		return readMemArg(r)
	default:
		// Remaining SIMD ops in active use have no immediates.
		return nil
	}
}

func readFEImmediate(r *wasmReader) error {
	sub, err := r.readVarU32()
	if err != nil {
		return err
	}
	if sub == 3 {
		_, err := r.readByte() // atomic.fence reserved immediate
		return err
	}
	return readMemArg(r)
}

func markBranchLoopEvidence(loops []loopEvidence, controlStack []controlFrame, depth uint32, exitCandidates []boundCandidate, continueCandidates []boundCandidate) {
	d := int(depth)
	if d < 0 || d >= len(controlStack) {
		return
	}
	targetIndex := len(controlStack) - 1 - d
	target := controlStack[targetIndex]
	if target.op == 0x03 {
		if target.loopIdx >= 0 && target.loopIdx < len(loops) {
			loop := &loops[target.loopIdx]
			loop.hasBackedge = true
			for _, candidate := range continueCandidates {
				markLoopCounterExit(loop, candidate)
			}
		}
		return
	}
	for i := len(controlStack) - 1; i > targetIndex; i-- {
		frame := controlStack[i]
		if frame.op != 0x03 || frame.loopIdx < 0 || frame.loopIdx >= len(loops) {
			continue
		}
		loop := &loops[frame.loopIdx]
		for _, candidate := range exitCandidates {
			markLoopCounterExit(loop, candidate)
		}
	}
}

func isLoopTarget(controlStack []controlFrame, depth uint32) bool {
	d := int(depth)
	if d < 0 || d >= len(controlStack) {
		return false
	}
	target := controlStack[len(controlStack)-1-d]
	return target.op == 0x03
}

func parseLimits(r *wasmReader) (memoryLimit, error) {
	flags, err := r.readByte()
	if err != nil {
		return memoryLimit{}, err
	}
	isMemory64 := (flags & 0x04) != 0
	if isMemory64 {
		min, err := r.readVarU64()
		if err != nil {
			return memoryLimit{}, err
		}
		limit := memoryLimit{
			Memory64: true,
			MinPages: min,
		}
		if (flags & 0x01) != 0 {
			max, err := r.readVarU64()
			if err != nil {
				return memoryLimit{}, err
			}
			limit.HasMax = true
			limit.MaxPages = max
		}
		return limit, nil
	}
	min32, err := r.readVarU32()
	if err != nil {
		return memoryLimit{}, err
	}
	limit := memoryLimit{MinPages: uint64(min32)}
	if (flags & 0x01) != 0 {
		max, err := r.readVarU32()
		if err != nil {
			return memoryLimit{}, err
		}
		limit.HasMax = true
		limit.MaxPages = uint64(max)
	}
	return limit, nil
}

func parseLimitsMin(r *wasmReader) (uint64, error) {
	limit, err := parseLimits(r)
	if err != nil {
		return 0, err
	}
	return limit.MinPages, nil
}

func skipLimits(r *wasmReader) error {
	_, err := parseLimitsMin(r)
	if err != nil {
		return err
	}
	return nil
}

func skipTableType(r *wasmReader) error {
	if _, err := r.readByte(); err != nil {
		return err
	}
	return skipLimits(r)
}

func skipGlobalType(r *wasmReader) error {
	if _, err := r.readByte(); err != nil {
		return err
	}
	if _, err := r.readByte(); err != nil {
		return err
	}
	return nil
}

func detectCallCycle(edges []map[int]struct{}) (bool, []int) {
	n := len(edges)
	if n == 0 {
		return false, nil
	}
	state := make([]uint8, n)
	stack := make([]int, 0, n)

	var cycle []int
	var visit func(int) bool
	visit = func(v int) bool {
		state[v] = 1
		stack = append(stack, v)

		for to := range edges[v] {
			if state[to] == 0 {
				if visit(to) {
					return true
				}
				continue
			}
			if state[to] == 1 {
				start := 0
				for i := len(stack) - 1; i >= 0; i-- {
					if stack[i] == to {
						start = i
						break
					}
				}
				cycle = append([]int(nil), stack[start:]...)
				return true
			}
		}

		stack = stack[:len(stack)-1]
		state[v] = 2
		return false
	}

	for i := range n {
		if state[i] == 0 {
			if visit(i) {
				return true, cycle
			}
		}
	}
	return false, nil
}
