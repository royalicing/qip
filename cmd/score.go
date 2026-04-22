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
	"github.com/royalicing/qip/internal/wasminspect"
)

type ScoreConfig struct {
	UsageScore string
	Stdout     io.Writer
	ReadFile   func(string) ([]byte, error)
}

type scoreResult struct {
	Path             string
	Metrics          wasminspect.ScoreMetrics
	JITScore         float64
	InterpScore      float64
	InstantiateScore float64
	RecursionCycle   bool
	RecursionFuncs   []int
	DefinedFuncBase  int
	Instantiation    wasminspect.InstantiationMetrics
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

	return scoreResult{
		Path:             path,
		Metrics:          analysis.Metrics,
		JITScore:         jit,
		InterpScore:      interp,
		InstantiateScore: instantiate,
		RecursionCycle:   hasCycle,
		RecursionFuncs:   cycle,
		DefinedFuncBase:  analysis.ImportedFuncCount,
		Instantiation:    analysis.Instantiation,
	}, nil
}

func computeScores(metrics wasminspect.ScoreMetrics) (jit float64, interp float64) {
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

func computeInstantiationScore(m wasminspect.InstantiationMetrics) float64 {
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

func printScoreSummary(out io.Writer, results []scoreResult) {
	tw := tabwriter.NewWriter(out, 0, 2, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, "MODULE\tJIT\tINTERPRETED\tINSTANTIATE\tSTATUS")
	for _, result := range results {
		jit := formatScore(result.JITScore)
		interp := formatScore(result.InterpScore)
		inst := formatScore(result.InstantiateScore)
		status := "OK"
		if result.RecursionCycle {
			jit = "FAIL"
			interp = "FAIL"
			status = "FAIL(recursion)"
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
	}
}

type instContributor struct {
	name  string
	value float64
}

func instantiationContributors(m wasminspect.InstantiationMetrics) []instContributor {
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
	return fmt.Sprintf("%.2f", v)
}

func analyzeWASMModule(wasm []byte) (wasminspect.Analysis, error) {
	return wasminspect.AnalyzeModule(wasm)
}

func detectCallCycle(edges []map[int]struct{}) (bool, []int) {
	return wasminspect.DetectCallCycle(edges)
}
