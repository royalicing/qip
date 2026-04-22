package cmd

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"

	qinternal "github.com/royalicing/qip/internal"
)

type ScoreConfig struct {
	UsageScore string
	Stdout     io.Writer
	ReadFile   func(string) ([]byte, error)
}

type scoreMetrics struct {
	InstructionTotal int
	BranchDecision   int // br_if + if
	BrTableCount     int
	BrTableTargets   int
	CallLocal        int
	CallIndirect     int
	CallImport       int
	LoopBackedge     int
}

type scoreResult struct {
	Path               string
	Metrics            scoreMetrics
	JITScore           float64
	InterpScore        float64
	InstantiateScore   float64
	RecursionCycle     bool
	RecursionFuncs     []int
	DefinedFuncBase    int
	Instantiation      instantiationMetrics
	ContractChecks     []contractCheck
	ContractCheckError bool
}

type functionMetrics struct {
	InstructionTotal int
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
	CallEdges         []map[int]struct{}
	ImportedFuncCount int
	ImportedGlobals   int
	FuncMetrics       []functionMetrics
	GlobalMetrics     []globalInitMetrics
	Instantiation     instantiationMetrics
	Exports           map[string]wasmExport
}

type importCounts struct {
	Funcs   int
	Globals int
}

const (
	scoreInstrJITWeight    = 0.02
	scoreInstrInterpWeight = 0.12

	scoreBranchJITWeight    = 1.0
	scoreBranchInterpWeight = 2.0

	scoreBrTableJITBase      = 1.0
	scoreBrTableInterpBase   = 2.0
	scoreBrTableJITPerTarget = 0.1
	scoreBrTableIntPerTarget = 0.5

	scoreCallLocalJITWeight    = 0.5
	scoreCallLocalInterpWeight = 5.0

	scoreCallIndirectJITWeight    = 20.0
	scoreCallIndirectInterpWeight = 50.0

	scoreCallImportJITWeight    = 20.0
	scoreCallImportInterpWeight = 50.0

	scoreLoopBackedgeJITWeight    = 1.0
	scoreLoopBackedgeInterpWeight = 3.0

	instantiateMemoryPageWeight    = 1.5
	instantiateTableElementWeight  = 0.05
	instantiateDataSegmentWeight   = 3.0
	instantiateDataKBWeight        = 0.05
	instantiateElemSegmentWeight   = 2.0
	instantiateElemElementWeight   = 0.1
	instantiateStartBaseWeight     = 20.0
	instantiateStartInstructionW   = 0.2
	instantiateStartCallWeight     = 8.0
	instantiateStartBranchWeight   = 2.0
	instantiateStartLoopBackWeight = 5.0
)

var qipContractExports = []string{
	"input_ptr",
	"input_utf8_cap",
	"input_bytes_cap",
	"output_ptr",
	"output_utf8_cap",
	"output_bytes_cap",
	"output_i32_cap",
	"input_content_type_ptr",
	"input_content_type_size",
	"output_content_type_ptr",
	"output_content_type_size",
}

func RunScore(args []string, config ScoreConfig) error {
	if config.Stdout == nil {
		config.Stdout = os.Stdout
	}
	if config.ReadFile == nil {
		config.ReadFile = os.ReadFile
	}

	fs := flag.NewFlagSet("score", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(normalizeScoreArgs(args)); err != nil {
		return fmt.Errorf("%s %w", config.UsageScore, err)
	}

	paths := fs.Args()
	if len(paths) == 0 {
		return errors.New(config.UsageScore)
	}

	results := make([]scoreResult, 0, len(paths))
	for _, modulePath := range paths {
		body, err := config.ReadFile(modulePath)
		if err != nil {
			return fmt.Errorf("score: read %s: %w", modulePath, err)
		}
		result, err := scoreModule(modulePath, body)
		if err != nil {
			return fmt.Errorf("score: analyze %s: %w", modulePath, err)
		}
		results = append(results, result)
	}

	printScoreSummary(config.Stdout, results)
	printScoreDetails(config.Stdout, results)

	failed := make([]string, 0, len(results))
	for _, result := range results {
		if result.RecursionCycle || result.ContractCheckError {
			failed = append(failed, result.Path)
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("score failed: one or more modules failed safety checks in %s", strings.Join(failed, ", "))
	}

	return nil
}

func normalizeScoreArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func scoreModule(path string, wasm []byte) (scoreResult, error) {
	analysis, err := analyzeWASMModule(wasm)
	if err != nil {
		return scoreResult{}, err
	}

	jit, interp := computeScores(analysis.Metrics)
	instantiate := computeInstantiationScore(analysis.Instantiation)
	hasCycle, cycle := detectCallCycle(analysis.CallEdges)
	if hasCycle {
		sort.Ints(cycle)
	}
	checks, contractFail := evaluateContractChecks(
		analysis.Exports,
		analysis.ImportedFuncCount,
		analysis.FuncMetrics,
		analysis.ImportedGlobals,
		analysis.GlobalMetrics,
	)

	return scoreResult{
		Path:               path,
		Metrics:            analysis.Metrics,
		JITScore:           jit,
		InterpScore:        interp,
		InstantiateScore:   instantiate,
		RecursionCycle:     hasCycle,
		RecursionFuncs:     cycle,
		DefinedFuncBase:    analysis.ImportedFuncCount,
		Instantiation:      analysis.Instantiation,
		ContractChecks:     checks,
		ContractCheckError: contractFail,
	}, nil
}

func computeScores(metrics scoreMetrics) (jit float64, interp float64) {
	jit += float64(metrics.InstructionTotal) * scoreInstrJITWeight
	interp += float64(metrics.InstructionTotal) * scoreInstrInterpWeight

	jit += float64(metrics.BranchDecision) * scoreBranchJITWeight
	interp += float64(metrics.BranchDecision) * scoreBranchInterpWeight

	jit += float64(metrics.BrTableCount)*scoreBrTableJITBase + float64(metrics.BrTableTargets)*scoreBrTableJITPerTarget
	interp += float64(metrics.BrTableCount)*scoreBrTableInterpBase + float64(metrics.BrTableTargets)*scoreBrTableIntPerTarget

	jit += float64(metrics.CallLocal) * scoreCallLocalJITWeight
	interp += float64(metrics.CallLocal) * scoreCallLocalInterpWeight

	jit += float64(metrics.CallIndirect) * scoreCallIndirectJITWeight
	interp += float64(metrics.CallIndirect) * scoreCallIndirectInterpWeight

	jit += float64(metrics.CallImport) * scoreCallImportJITWeight
	interp += float64(metrics.CallImport) * scoreCallImportInterpWeight

	jit += float64(metrics.LoopBackedge) * scoreLoopBackedgeJITWeight
	interp += float64(metrics.LoopBackedge) * scoreLoopBackedgeInterpWeight

	return jit, interp
}

func computeInstantiationScore(m instantiationMetrics) float64 {
	score := 0.0
	score += float64(m.MemoryMinPages) * instantiateMemoryPageWeight
	score += float64(m.TableMinElements) * instantiateTableElementWeight
	score += float64(m.ActiveDataSegments) * instantiateDataSegmentWeight
	score += (float64(m.ActiveDataBytes) / 1024.0) * instantiateDataKBWeight
	score += float64(m.ActiveElemSegments) * instantiateElemSegmentWeight
	score += float64(m.ActiveElemElements) * instantiateElemElementWeight
	if m.HasStart {
		score += instantiateStartBaseWeight
		score += float64(m.StartInstructionCnt) * instantiateStartInstructionW
		score += float64(m.StartCalls) * instantiateStartCallWeight
		score += float64(m.StartBranches) * instantiateStartBranchWeight
		score += float64(m.StartLoopBackedges) * instantiateStartLoopBackWeight
	}
	return score
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

func printScoreSummary(out io.Writer, results []scoreResult) {
	tw := tabwriter.NewWriter(out, 0, 2, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, "MODULE\tJIT\tINTERPRETED\tINSTANTIATE\tSTATUS")
	for _, result := range results {
		jit := formatScore(result.JITScore)
		interp := formatScore(result.InterpScore)
		inst := formatScore(result.InstantiateScore)
		statuses := make([]string, 0, 2)
		if result.RecursionCycle {
			jit = "FAIL"
			interp = "FAIL"
			statuses = append(statuses, "recursion")
		}
		if result.ContractCheckError {
			statuses = append(statuses, "contract")
		}
		status := "OK"
		if len(statuses) > 0 {
			status = "FAIL(" + strings.Join(statuses, ",") + ")"
		}
		_, _ = fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", result.Path, jit, interp, inst, status)
	}
	_ = tw.Flush()
}

func printScoreDetails(out io.Writer, results []scoreResult) {
	for _, result := range results {
		_, _ = fmt.Fprintln(out)
		_, _ = fmt.Fprintf(out, "module: %s\n", result.Path)
		_, _ = fmt.Fprintf(out, "  instr_total: %d\n", result.Metrics.InstructionTotal)
		_, _ = fmt.Fprintf(out, "  branch_decisions (br_if + if): %d\n", result.Metrics.BranchDecision)
		_, _ = fmt.Fprintf(out, "  br_table_count: %d\n", result.Metrics.BrTableCount)
		_, _ = fmt.Fprintf(out, "  br_table_targets: %d\n", result.Metrics.BrTableTargets)
		_, _ = fmt.Fprintf(out, "  call_local: %d\n", result.Metrics.CallLocal)
		_, _ = fmt.Fprintf(out, "  call_indirect: %d\n", result.Metrics.CallIndirect)
		_, _ = fmt.Fprintf(out, "  call_import: %d\n", result.Metrics.CallImport)
		_, _ = fmt.Fprintf(out, "  loop_backedge: %d\n", result.Metrics.LoopBackedge)
		_, _ = fmt.Fprintf(out, "  score_jit: %s\n", formatScore(result.JITScore))
		_, _ = fmt.Fprintf(out, "  score_interp: %s\n", formatScore(result.InterpScore))

		_, _ = fmt.Fprintf(out, "  instantiation_score: %s\n", formatScore(result.InstantiateScore))
		_, _ = fmt.Fprintf(out, "  memory_min_pages: %d\n", result.Instantiation.MemoryMinPages)
		_, _ = fmt.Fprintf(out, "  table_min_elements: %d\n", result.Instantiation.TableMinElements)
		_, _ = fmt.Fprintf(out, "  active_data_segments: %d\n", result.Instantiation.ActiveDataSegments)
		_, _ = fmt.Fprintf(out, "  active_data_bytes: %d\n", result.Instantiation.ActiveDataBytes)
		_, _ = fmt.Fprintf(out, "  active_elem_segments: %d\n", result.Instantiation.ActiveElemSegments)
		_, _ = fmt.Fprintf(out, "  active_elem_elements: %d\n", result.Instantiation.ActiveElemElements)
		_, _ = fmt.Fprintf(out, "  has_start: %t\n", result.Instantiation.HasStart)
		if result.Instantiation.HasStart {
			_, _ = fmt.Fprintf(out, "  start_instr_total: %d\n", result.Instantiation.StartInstructionCnt)
			_, _ = fmt.Fprintf(out, "  start_calls: %d\n", result.Instantiation.StartCalls)
			_, _ = fmt.Fprintf(out, "  start_branches: %d\n", result.Instantiation.StartBranches)
			_, _ = fmt.Fprintf(out, "  start_loop_backedge: %d\n", result.Instantiation.StartLoopBackedges)
		}
		_, _ = fmt.Fprintln(out, "  instantiation_contributors:")
		contribs := instantiationContributors(result.Instantiation)
		for _, c := range contribs {
			_, _ = fmt.Fprintf(out, "    - %s: %s\n", c.name, formatScore(c.value))
		}

		if result.RecursionCycle {
			global := make([]string, 0, len(result.RecursionFuncs))
			for _, fn := range result.RecursionFuncs {
				global = append(global, strconv.Itoa(result.DefinedFuncBase+fn))
			}
			_, _ = fmt.Fprintf(out, "  recursion: FAIL (defined functions=%v, global indices=%v)\n", result.RecursionFuncs, global)
		}

		if len(result.ContractChecks) == 0 {
			_, _ = fmt.Fprintln(out, "  contract_checks: SKIP (no qip contract exports found)")
		} else {
			status := "PASS"
			if result.ContractCheckError {
				status = "FAIL"
			}
			_, _ = fmt.Fprintf(out, "  contract_checks: %s (%d checked)\n", status, len(result.ContractChecks))
			for _, check := range result.ContractChecks {
				line := fmt.Sprintf("    - %s (%s): PASS", check.Export, check.Kind)
				if !check.Pass {
					line = fmt.Sprintf("    - %s (%s): FAIL (%s)", check.Export, check.Kind, check.Reason)
				}
				_, _ = fmt.Fprintln(out, line)
			}
		}
	}
}

type instContributor struct {
	name  string
	value float64
}

func instantiationContributors(m instantiationMetrics) []instContributor {
	parts := []instContributor{
		{name: "memory_pages", value: float64(m.MemoryMinPages) * instantiateMemoryPageWeight},
		{name: "table_elements", value: float64(m.TableMinElements) * instantiateTableElementWeight},
		{name: "active_data_segments", value: float64(m.ActiveDataSegments) * instantiateDataSegmentWeight},
		{name: "active_data_bytes", value: (float64(m.ActiveDataBytes) / 1024.0) * instantiateDataKBWeight},
		{name: "active_elem_segments", value: float64(m.ActiveElemSegments) * instantiateElemSegmentWeight},
		{name: "active_elem_elements", value: float64(m.ActiveElemElements) * instantiateElemElementWeight},
	}
	if m.HasStart {
		parts = append(parts,
			instContributor{name: "start_base", value: instantiateStartBaseWeight},
			instContributor{name: "start_instr_total", value: float64(m.StartInstructionCnt) * instantiateStartInstructionW},
			instContributor{name: "start_calls", value: float64(m.StartCalls) * instantiateStartCallWeight},
			instContributor{name: "start_branches", value: float64(m.StartBranches) * instantiateStartBranchWeight},
			instContributor{name: "start_loop_backedge", value: float64(m.StartLoopBackedges) * instantiateStartLoopBackWeight},
		)
	}
	sort.Slice(parts, func(i, j int) bool { return parts[i].value > parts[j].value })
	return parts
}

func formatScore(v float64) string {
	// Keep a stable, easy-to-diff fixed precision for CLI and tests.
	return fmt.Sprintf("%.2f", v)
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
		Exports: map[string]wasmExport{},
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
			min, err := parseMemorySection(payload)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse memory section: %w", err)
			}
			analysis.Instantiation.MemoryMinPages = min
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
			edges, fnMetrics, err := parseCodeSection(payload, imports.Funcs, len(functionTypeIdx), &analysis.Metrics)
			if err != nil {
				return wasmAnalysis{}, fmt.Errorf("parse code section: %w", err)
			}
			analysis.CallEdges = edges
			analysis.FuncMetrics = fnMetrics
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
			if err := skipLimits(r); err != nil {
				return importCounts{}, err
			}
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

func parseMemorySection(payload []byte) (uint64, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return 0, err
	}
	var minPages uint64
	for i := 0; i < int(n); i++ {
		min, err := parseLimitsMin(r)
		if err != nil {
			return 0, err
		}
		minPages += min
	}
	if r.remaining() != 0 {
		return 0, errors.New("trailing bytes in memory section")
	}
	return minPages, nil
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
) ([]map[int]struct{}, []functionMetrics, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, nil, err
	}
	if int(n) != definedFuncCount {
		return nil, nil, fmt.Errorf("function/code count mismatch: function=%d code=%d", definedFuncCount, n)
	}
	edges := make([]map[int]struct{}, definedFuncCount)
	funcMetrics := make([]functionMetrics, definedFuncCount)
	for i := 0; i < int(n); i++ {
		bodySize, err := r.readVarU32()
		if err != nil {
			return nil, nil, err
		}
		body, err := r.readN(int(bodySize))
		if err != nil {
			return nil, nil, err
		}
		fm, err := parseFunctionBody(body, i, importedFuncCount, definedFuncCount, metrics, edges)
		if err != nil {
			return nil, nil, fmt.Errorf("function %d: %w", i, err)
		}
		funcMetrics[i] = fm
	}
	if r.remaining() != 0 {
		return nil, nil, errors.New("trailing bytes in code section")
	}
	return edges, funcMetrics, nil
}

func parseFunctionBody(
	body []byte,
	funcIdx int,
	importedFuncCount int,
	definedFuncCount int,
	metrics *scoreMetrics,
	edges []map[int]struct{},
) (functionMetrics, error) {
	r := newWasmReader(body)
	localDecls, err := r.readVarU32()
	if err != nil {
		return functionMetrics{}, err
	}
	for i := 0; i < int(localDecls); i++ {
		if _, err := r.readVarU32(); err != nil {
			return functionMetrics{}, err
		}
		if _, err := r.readByte(); err != nil {
			return functionMetrics{}, err
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
	controlStack := make([]byte, 0, 16)

	addInstr := func() {
		metrics.InstructionTotal++
		fm.InstructionTotal++
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
			return functionMetrics{}, err
		}
		addInstr()

		switch op {
		case 0x00, 0x01, opElse, 0x0f, 0x1a, 0x1b:
			// no immediate
			if op == 0x1b {
				fm.ControlFlowOps++
			}
		case opBlock, opLoop, opIf:
			if err := readBlockType(r); err != nil {
				return functionMetrics{}, err
			}
			if op == opIf {
				addBranch()
			} else {
				fm.ControlFlowOps++
			}
			controlStack = append(controlStack, op)
		case opEnd:
			if len(controlStack) == 0 {
				if r.remaining() != 0 {
					return functionMetrics{}, errors.New("trailing bytes after final end")
				}
				return fm, nil
			}
			controlStack = controlStack[:len(controlStack)-1]
		case 0x0c:
			depth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, err
			}
			fm.ControlFlowOps++
			if isLoopTarget(controlStack, depth) {
				addLoopBack()
			}
		case 0x0d:
			depth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, err
			}
			addBranch()
			if isLoopTarget(controlStack, depth) {
				addLoopBack()
			}
		case 0x0e:
			targetCount, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, err
			}
			addBrTable(int(targetCount))
			hasLoopTarget := false
			for i := 0; i < int(targetCount); i++ {
				depth, err := r.readVarU32()
				if err != nil {
					return functionMetrics{}, err
				}
				if isLoopTarget(controlStack, depth) {
					hasLoopTarget = true
				}
			}
			defaultDepth, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, err
			}
			if isLoopTarget(controlStack, defaultDepth) {
				hasLoopTarget = true
			}
			if hasLoopTarget {
				addLoopBack()
			}
		case 0x10, 0x12:
			idx, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, err
			}
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
				return functionMetrics{}, err
			}
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, err
			}
			addCallIndirect()
			fm.TableOps++
		case 0x14:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, err
			}
			addCallIndirect()
		case 0x1c:
			count, err := r.readVarU32()
			if err != nil {
				return functionMetrics{}, err
			}
			if _, err := r.readN(int(count)); err != nil {
				return functionMetrics{}, err
			}
		case 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, err
			}
			switch op {
			case 0x25, 0x26:
				fm.TableOps++
			default:
				fm.LocalOps++
			}
		case 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
			0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
			0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e:
			if err := readMemArg(r); err != nil {
				return functionMetrics{}, err
			}
			fm.MemoryOps++
		case 0x3f, 0x40:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, err
			}
			fm.MemoryOps++
		case 0x41:
			if _, err := r.readVarS32(); err != nil {
				return functionMetrics{}, err
			}
		case 0x42:
			if _, err := r.readVarS64(10); err != nil {
				return functionMetrics{}, err
			}
		case 0x43:
			if _, err := r.readN(4); err != nil {
				return functionMetrics{}, err
			}
		case 0x44:
			if _, err := r.readN(8); err != nil {
				return functionMetrics{}, err
			}
		case 0xd0:
			if _, err := r.readByte(); err != nil {
				return functionMetrics{}, err
			}
		case 0xd2:
			if _, err := r.readVarU32(); err != nil {
				return functionMetrics{}, err
			}
		case 0xfc:
			if err := readFCImmediate(r); err != nil {
				return functionMetrics{}, err
			}
			fm.MemoryOps++
		case 0xfd:
			if err := readFDImmediate(r); err != nil {
				return functionMetrics{}, err
			}
			fm.MemoryOps++
		case 0xfe:
			if err := readFEImmediate(r); err != nil {
				return functionMetrics{}, err
			}
			fm.MemoryOps++
		default:
			// Most core numeric/reference ops have no immediates.
		}
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
	case 0: // memory.init
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 1: // data.drop
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 2: // memory.copy
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 3: // memory.fill
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 4: // table.init
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 5: // elem.drop
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 6: // table.copy
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readVarU32(); err != nil {
			return err
		}
	case 7, 8, 9: // table.grow/size/fill
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
	case sub == 84 || sub == 85:
		return readMemArg(r)
	case sub >= 92 && sub <= 99:
		if err := readMemArg(r); err != nil {
			return err
		}
		_, err := r.readByte()
		return err
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

func isLoopTarget(controlStack []byte, depth uint32) bool {
	d := int(depth)
	if d < 0 || d >= len(controlStack) {
		return false
	}
	target := controlStack[len(controlStack)-1-d]
	return target == 0x03
}

func parseLimitsMin(r *wasmReader) (uint64, error) {
	flags, err := r.readByte()
	if err != nil {
		return 0, err
	}
	isMemory64 := (flags & 0x04) != 0
	if isMemory64 {
		min, err := r.readVarU64()
		if err != nil {
			return 0, err
		}
		if (flags & 0x01) != 0 {
			if _, err := r.readVarU64(); err != nil {
				return 0, err
			}
		}
		return min, nil
	}
	min32, err := r.readVarU32()
	if err != nil {
		return 0, err
	}
	if (flags & 0x01) != 0 {
		if _, err := r.readVarU32(); err != nil {
			return 0, err
		}
	}
	return uint64(min32), nil
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
