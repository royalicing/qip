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
	Path            string
	Metrics         scoreMetrics
	JITScore        float64
	InterpScore     float64
	RecursionCycle  bool
	RecursionFuncs  []int
	DefinedFuncBase int
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
)

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
		if result.RecursionCycle {
			failed = append(failed, result.Path)
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("score failed: recursion cycle detected in %s", strings.Join(failed, ", "))
	}

	return nil
}

func normalizeScoreArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func scoreModule(path string, wasm []byte) (scoreResult, error) {
	metrics, callEdges, importedFuncCount, err := analyzeWASMModule(wasm)
	if err != nil {
		return scoreResult{}, err
	}

	jit, interp := computeScores(metrics)
	hasCycle, cycle := detectCallCycle(callEdges)
	if hasCycle {
		sort.Ints(cycle)
	}

	return scoreResult{
		Path:            path,
		Metrics:         metrics,
		JITScore:        jit,
		InterpScore:     interp,
		RecursionCycle:  hasCycle,
		RecursionFuncs:  cycle,
		DefinedFuncBase: importedFuncCount,
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

func printScoreSummary(out io.Writer, results []scoreResult) {
	tw := tabwriter.NewWriter(out, 0, 2, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, "MODULE\tJIT\tINTERPRETED\tSTATUS")
	for _, result := range results {
		jit := formatScore(result.JITScore)
		interp := formatScore(result.InterpScore)
		status := "OK"
		if result.RecursionCycle {
			jit = "FAIL"
			interp = "FAIL"
			status = "FAIL(recursion)"
		}
		_, _ = fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", result.Path, jit, interp, status)
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

		if result.RecursionCycle {
			global := make([]string, 0, len(result.RecursionFuncs))
			for _, fn := range result.RecursionFuncs {
				global = append(global, strconv.Itoa(result.DefinedFuncBase+fn))
			}
			_, _ = fmt.Fprintf(out, "  recursion: FAIL (defined functions=%v, global indices=%v)\n", result.RecursionFuncs, global)
			continue
		}
		_, _ = fmt.Fprintf(out, "  score_jit: %s\n", formatScore(result.JITScore))
		_, _ = fmt.Fprintf(out, "  score_interp: %s\n", formatScore(result.InterpScore))
		_, _ = fmt.Fprintf(out, "  range: [%s, %s]\n", formatScore(result.JITScore), formatScore(result.InterpScore))
	}
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

func analyzeWASMModule(wasm []byte) (scoreMetrics, []map[int]struct{}, int, error) {
	if len(wasm) < 8 {
		return scoreMetrics{}, nil, 0, errors.New("invalid wasm: file too small")
	}
	if string(wasm[0:4]) != "\x00asm" {
		return scoreMetrics{}, nil, 0, errors.New("invalid wasm: bad magic")
	}
	if wasm[4] != 0x01 || wasm[5] != 0x00 || wasm[6] != 0x00 || wasm[7] != 0x00 {
		return scoreMetrics{}, nil, 0, errors.New("invalid wasm: unsupported version")
	}

	r := newWasmReader(wasm[8:])
	var importedFuncCount int
	var functionTypeIdx []uint32
	var metrics scoreMetrics
	var callEdges []map[int]struct{}

	for r.remaining() > 0 {
		sectionID, err := r.readByte()
		if err != nil {
			return scoreMetrics{}, nil, 0, fmt.Errorf("read section id at offset %d: %w", r.offset()+8, err)
		}
		sectionSize, err := r.readVarU32()
		if err != nil {
			return scoreMetrics{}, nil, 0, fmt.Errorf("read section size at offset %d: %w", r.offset()+8, err)
		}
		payload, err := r.readN(int(sectionSize))
		if err != nil {
			return scoreMetrics{}, nil, 0, fmt.Errorf("read section payload id=%d at offset %d: %w", sectionID, r.offset()+8, err)
		}

		switch sectionID {
		case 0:
			// custom section
		case 1:
			if err := parseTypeSection(payload); err != nil {
				return scoreMetrics{}, nil, 0, fmt.Errorf("parse type section: %w", err)
			}
		case 2:
			count, err := parseImportSection(payload)
			if err != nil {
				return scoreMetrics{}, nil, 0, fmt.Errorf("parse import section: %w", err)
			}
			importedFuncCount = count
		case 3:
			idxs, err := parseFunctionSection(payload)
			if err != nil {
				return scoreMetrics{}, nil, 0, fmt.Errorf("parse function section: %w", err)
			}
			functionTypeIdx = idxs
		case 10:
			edges, err := parseCodeSection(payload, importedFuncCount, len(functionTypeIdx), &metrics)
			if err != nil {
				return scoreMetrics{}, nil, 0, fmt.Errorf("parse code section: %w", err)
			}
			callEdges = edges
		}
	}

	if len(functionTypeIdx) != 0 && callEdges == nil {
		return scoreMetrics{}, nil, 0, errors.New("invalid wasm: function section without code section")
	}
	if callEdges == nil {
		callEdges = make([]map[int]struct{}, 0)
	}
	return metrics, callEdges, importedFuncCount, nil
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

func parseImportSection(payload []byte) (int, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return 0, err
	}
	funcImports := 0
	for i := 0; i < int(n); i++ {
		if _, err := r.readName(); err != nil {
			return 0, err
		}
		if _, err := r.readName(); err != nil {
			return 0, err
		}
		kind, err := r.readByte()
		if err != nil {
			return 0, err
		}
		switch kind {
		case 0x00: // func
			if _, err := r.readVarU32(); err != nil {
				return 0, err
			}
			funcImports++
		case 0x01: // table
			if err := skipTableType(r); err != nil {
				return 0, err
			}
		case 0x02: // memory
			if err := skipLimits(r); err != nil {
				return 0, err
			}
		case 0x03: // global
			if err := skipGlobalType(r); err != nil {
				return 0, err
			}
		case 0x04: // tag
			if _, err := r.readByte(); err != nil {
				return 0, err
			}
			if _, err := r.readVarU32(); err != nil {
				return 0, err
			}
		default:
			return 0, fmt.Errorf("unsupported import kind 0x%x", kind)
		}
	}
	if r.remaining() != 0 {
		return 0, errors.New("trailing bytes in import section")
	}
	return funcImports, nil
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

func parseCodeSection(payload []byte, importedFuncCount int, definedFuncCount int, metrics *scoreMetrics) ([]map[int]struct{}, error) {
	r := newWasmReader(payload)
	n, err := r.readVarU32()
	if err != nil {
		return nil, err
	}
	if int(n) != definedFuncCount {
		return nil, fmt.Errorf("function/code count mismatch: function=%d code=%d", definedFuncCount, n)
	}
	edges := make([]map[int]struct{}, definedFuncCount)
	for i := 0; i < int(n); i++ {
		bodySize, err := r.readVarU32()
		if err != nil {
			return nil, err
		}
		body, err := r.readN(int(bodySize))
		if err != nil {
			return nil, err
		}
		if err := parseFunctionBody(body, i, importedFuncCount, definedFuncCount, metrics, edges); err != nil {
			return nil, fmt.Errorf("function %d: %w", i, err)
		}
	}
	if r.remaining() != 0 {
		return nil, errors.New("trailing bytes in code section")
	}
	return edges, nil
}

func parseFunctionBody(body []byte, funcIdx int, importedFuncCount int, definedFuncCount int, metrics *scoreMetrics, edges []map[int]struct{}) error {
	r := newWasmReader(body)
	localDecls, err := r.readVarU32()
	if err != nil {
		return err
	}
	for i := 0; i < int(localDecls); i++ {
		if _, err := r.readVarU32(); err != nil {
			return err
		}
		if _, err := r.readByte(); err != nil {
			return err
		}
	}

	const (
		opBlock = 0x02
		opLoop  = 0x03
		opIf    = 0x04
		opElse  = 0x05
		opEnd   = 0x0b
	)

	controlStack := make([]byte, 0, 16)

	for {
		op, err := r.readByte()
		if err != nil {
			return err
		}
		metrics.InstructionTotal++

		switch op {
		case 0x00, 0x01, opElse, 0x0f, 0x1a, 0x1b:
			// no immediate
		case opBlock, opLoop, opIf:
			if err := readBlockType(r); err != nil {
				return err
			}
			if op == opIf {
				metrics.BranchDecision++
			}
			controlStack = append(controlStack, op)
		case opEnd:
			if len(controlStack) == 0 {
				if r.remaining() != 0 {
					return errors.New("trailing bytes after final end")
				}
				return nil
			}
			controlStack = controlStack[:len(controlStack)-1]
		case 0x0c:
			depth, err := r.readVarU32()
			if err != nil {
				return err
			}
			if isLoopTarget(controlStack, depth) {
				metrics.LoopBackedge++
			}
		case 0x0d:
			depth, err := r.readVarU32()
			if err != nil {
				return err
			}
			metrics.BranchDecision++
			if isLoopTarget(controlStack, depth) {
				metrics.LoopBackedge++
			}
		case 0x0e:
			targetCount, err := r.readVarU32()
			if err != nil {
				return err
			}
			metrics.BrTableCount++
			metrics.BrTableTargets += int(targetCount)
			hasLoopTarget := false
			for i := 0; i < int(targetCount); i++ {
				depth, err := r.readVarU32()
				if err != nil {
					return err
				}
				if isLoopTarget(controlStack, depth) {
					hasLoopTarget = true
				}
			}
			defaultDepth, err := r.readVarU32()
			if err != nil {
				return err
			}
			if isLoopTarget(controlStack, defaultDepth) {
				hasLoopTarget = true
			}
			if hasLoopTarget {
				metrics.LoopBackedge++
			}
		case 0x10, 0x12:
			idx, err := r.readVarU32()
			if err != nil {
				return err
			}
			if int(idx) < importedFuncCount {
				metrics.CallImport++
			} else {
				metrics.CallLocal++
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
				return err
			}
			if _, err := r.readVarU32(); err != nil {
				return err
			}
			metrics.CallIndirect++
		case 0x14:
			if _, err := r.readVarU32(); err != nil {
				return err
			}
			metrics.CallIndirect++
		case 0x1c:
			count, err := r.readVarU32()
			if err != nil {
				return err
			}
			if _, err := r.readN(int(count)); err != nil {
				return err
			}
		case 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26:
			if _, err := r.readVarU32(); err != nil {
				return err
			}
		case 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
			0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
			0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e:
			if err := readMemArg(r); err != nil {
				return err
			}
		case 0x3f, 0x40:
			if _, err := r.readVarU32(); err != nil {
				return err
			}
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
		case 0xd2:
			if _, err := r.readVarU32(); err != nil {
				return err
			}
		case 0xfc:
			if err := readFCImmediate(r); err != nil {
				return err
			}
		case 0xfd:
			if err := readFDImmediate(r); err != nil {
				return err
			}
		case 0xfe:
			if err := readFEImmediate(r); err != nil {
				return err
			}
		default:
			// Most core numeric/reference ops have no immediates.
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

func skipLimits(r *wasmReader) error {
	flags, err := r.readByte()
	if err != nil {
		return err
	}
	isMemory64 := (flags & 0x04) != 0
	if isMemory64 {
		if _, err := r.readVarU64(); err != nil {
			return err
		}
		if (flags & 0x01) != 0 {
			if _, err := r.readVarU64(); err != nil {
				return err
			}
		}
		return nil
	}
	if _, err := r.readVarU32(); err != nil {
		return err
	}
	if (flags & 0x01) != 0 {
		if _, err := r.readVarU32(); err != nil {
			return err
		}
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
