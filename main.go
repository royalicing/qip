package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html"
	"image"
	"image/draw"
	"image/jpeg"
	"image/png"
	"io"
	"io/fs"
	"log"
	"math"
	"mime"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
	"unsafe"

	qcmd "github.com/royalicing/qip/cmd"
	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

type dataEncoding uint8

const (
	dataEncodingRaw dataEncoding = iota
	dataEncodingUTF8
	dataEncodingArrayI32
)

const tileSize = 64
const applicationWARCRecipeMIME = "application/warc"

const (
	defaultRouteContentRecipeTimeout   = 100 * time.Millisecond
	defaultRouteApplicationWARCTimeout = 100 * time.Millisecond
	defaultRouteWARCTransformTimeout   = 5 * time.Second
)

type routeHandlerTimeouts struct {
	contentRecipe   time.Duration
	applicationWARC time.Duration
}

type tileStage struct {
	mod         api.Module
	mem         api.Memory
	tileFunc    api.Function
	inputPtr    uint32
	uniformFunc api.Function
	haloFunc    api.Function
	inputCap    uint64
	haloPx      int
	tileSpan    int
}

type moduleSpec struct {
	path     string
	uniforms map[string]string
}

type contentData struct {
	bytes    []byte
	encoding dataEncoding
}

type runtimeMode string

const (
	modeDev  runtimeMode = "dev"
	modeProd runtimeMode = "prod"
)

type contentTypeCheckingMode uint8

const (
	ContentTypeCheckingStrong contentTypeCheckingMode = iota
	ContentTypeCheckingNone
)

type options struct {
	verbose                bool
	mode                   runtimeMode
	contentTypeChecking    contentTypeCheckingMode
	trustFirstStageContent bool
	viewSource             bool
}

const usageMain = "Usage: qip <command> [args]\n\nCommands:\n  run      Run a chain of wasm modules on input\n  bench    Compare one or more wasm modules for output parity and performance\n  image    Run wasm filters on an input image\n  comply   Validate module ABI and run compliance check modules\n  dev      Start a dev server for a content directory with optional recipes\n  route    Resolve routed paths and export route artifacts\n  form     Run an interactive wasm form module in the terminal\n  help     Show command help"
const usageRun = "Usage: qip run [-v] [-i <input>] [-o <output file or ->] [--timeout-ms <ms>] <wasm module URL or file> [?key=value[&key2=value2...] ...] ..."
const usageBench = "Usage: qip bench -i <input> [-r <benchmark runs> | --benchtime=<duration>] [--timeout-ms <ms>] <module1> [module2 ...]"
const usageImage = "Usage: qip image -i <input image path or -> -o <output image path> [--timeout-ms <ms>] [-v] <wasm module URL or file> [?key=value[&key2=value2...] ...] ..."
const usageDev = "Usage: qip dev <content_dir> [--recipes <recipes_dir>] [--forms <forms_dir>] [--modules <modules_dir>] [--mode <dev|prod>] [--view-source] [-p <port>] [-v|--verbose]"
const usageRoute = "Usage: qip route <subcommand> [args]\n\nSubcommands:\n  get      Resolve one GET path through the dev router and print the result\n  head     Resolve one HEAD path through the dev router and print headers\n  list     List routed paths and content types\n  warc     Archive the routed site and write a minimal WARC file"
const usageRouteGet = "Usage: qip route get <content_dir> <path> [--recipes <recipes_dir>] [--forms <forms_dir>] [--modules <modules_dir>] [--mode <dev|prod>] [-v|--verbose]"
const usageRouteHead = "Usage: qip route head <content_dir> <path> [--recipes <recipes_dir>] [--forms <forms_dir>] [--modules <modules_dir>] [--mode <dev|prod>] [-v|--verbose]"
const usageRouteList = "Usage: qip route list <content_dir> [--recipes <recipes_dir>] [--forms <forms_dir>] [--modules <modules_dir>] [--mode <dev|prod>] [-v|--verbose]"
const usageRouteWarc = "Usage: qip route warc <content_dir> [--recipes <recipes_dir>] [--forms <forms_dir>] [--modules <modules_dir>] [--mode <dev|prod>] [--host <host>] [--view-source] [-o <warc file or ->] [-v|--verbose]"
const usageForm = "Usage: qip form [-v|--verbose] <wasm module URL or file>"
const usageHelp = "Usage: qip help [command]"

var qipFormTagPattern = regexp.MustCompile(`(?is)<qip-form\b[^>]*>`)
var qipFormNamePattern = regexp.MustCompile("(?is)\\bname\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+))")
var qipPreviewTagPattern = regexp.MustCompile(`(?is)<qip-preview\b[^>]*>`)

const helpRun = "Usage: qip run [-v] [-i <input>] [-o <output file or ->] [--timeout-ms <ms>] <wasm module URL or file> [?key=value[&key2=value2...] ...] ...\n\nModule contracts:\n  Run mode:\n    - Exports run(input_size), input_ptr, and input_utf8_cap or input_bytes_cap\n    - Exports output_ptr and output_utf8_cap or output_bytes_cap or output_i32_cap\n    - Optional uniforms: uniform_set_<key>(value)\n  Image mode:\n    - Exports tile_rgba_f32_64x64, input_ptr, input_bytes_cap\n    - Optional: uniform_set_width_and_height, calculate_halo_px\n\nOutput:\n  - Default output is stdout.\n  - Use -o <path> to write to a file.\n  - If -o ends with .png/.jpg/.jpeg/.bmp and pipeline output is an image,\n    qip re-encodes to the requested output image format.\n\nUniform args:\n  Place a query string immediately after a module path to set that module's uniforms.\n  Quote the full query arg in your shell (for example, to avoid '&' splitting).\n  Example: modules/utf8/text-to-bmp.wasm '?cols=120&leading=24'\n  Example: modules/utf8/text-to-path-svg-dejavu-sans-mono.wasm '?width=900&height=400&font_size=48'\n\nComposition:\n  If a module exports tile_rgba_f32_64x64, qip run composes a contiguous image stage block.\n  Input to that block must be BMP bytes and the block outputs BMP bytes.\n  Run stages may follow and will receive BMP bytes.\n\nExample:\n  echo '<svg width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"#d52b1e\" /><rect x=\"13\" y=\"6\" width=\"6\" height=\"20\" fill=\"#ffffff\" /><rect x=\"6\" y=\"13\" width=\"20\" height=\"6\" fill=\"#ffffff\" /></svg>' | ./qip run -o out.ico modules/image/svg+xml/svg-rasterize.wasm modules/image/bmp/bmp-double.wasm modules/image/bmp/bmp-to-ico.wasm"
const helpComply = `Usage: qip comply <impl.wasm> [--with <compliance.wasm> ...] [-v|--verbose] [--timeout-ms <ms>]

What qip comply does:
  1) Base ABI validation on impl.wasm (always):
     - impl must export memory
     - detects module kind: run, tile, or run+tile
     - run kind requires:
         run(i32) -> i32
         input_ptr (global i32 or function () -> i32)
         input_utf8_cap or input_bytes_cap (global i32 or function () -> i32)
     - tile kind requires:
         tile_rgba_f32_64x64(f32, f32) -> ()
         input_ptr (global i32 or function () -> i32)
         input_bytes_cap (global i32 or function () -> i32)

  2) Executes each --with compliance module:
     - qip instantiates impl as module name "impl"
     - all compliance modules run in parallel
     - all must pass

Compliance module contract (what to implement):
  Required imports/exports:
    - must import impl.memory
    - must export positive() -> i32
  Optional:
    - export negative() -> i32
    - import qip.run_must_trap(i32) -> i32 for negative tests that expect trap

Status convention:
  - return > 0 to pass
  - return <= 0 to fail
  - positive() trap always fails
  - if negative() exists, it runs on a fresh impl instance
  - negative() returning <= 0 fails (use run_must_trap when trap is expected)

Memory model for compliance modules:
  - compliance imports impl.memory, so both modules see the same linear memory
  - to test a run module, compliance usually:
      - calls impl.input_ptr() and impl.input_utf8_cap()/input_bytes_cap()
      - writes test input bytes into impl.memory at input_ptr
      - calls impl.run(input_size)
      - reads output from impl.output_ptr() and returned output size

Failure detail exports (optional but recommended):
  Export pointer/size pairs so qip can print reproducible context:
    - failure_message_ptr / failure_message_size
    - failure_input_ptr / failure_input_size
    - failure_expected_output_ptr / failure_expected_output_size
    - failure_actual_output_ptr / failure_actual_output_size
  Legacy output fallback also supported:
    - failure_output_ptr / failure_output_size
  Aliases with fail_* prefix are also accepted.

Minimal WAT template (run module checker):
  (module
    (import "impl" "memory" (memory 1))
    (import "impl" "input_ptr" (func $input_ptr (result i32)))
    (import "impl" "run" (func $run (param i32) (result i32)))
    (import "impl" "output_ptr" (func $output_ptr (result i32)))

    (func (export "positive") (result i32)
      ;; write input at (call $input_ptr), call $run, compare output, return >0 on pass
      i32.const 1)

    ;; optional negative phase:
    ;; (import "qip" "run_must_trap" (func $run_must_trap (param i32) (result i32)))
    ;; (func (export "negative") (result i32) ...)
  )

Authoring workflow for agents:
  1) Build impl wasm.
  2) Run: qip comply impl.wasm --with compliance.wasm
  3) On failure, inspect printed message/input/expected/actual previews.
  4) Update impl or compliance module and repeat until PASS.`

func main() {
	args := os.Args[1:]

	if len(args) == 0 {
		gameOver(usageMain)
	}

	if args[0] == "-v" || args[0] == "--verbose" {
		gameOver(usageMain)
	}

	switch args[0] {
	case "help", "doc":
		helpCmd(args[1:])
	case "run":
		runCmd(args[1:])
	case "bench":
		benchCmd(args[1:])
	case "image":
		imageCmd(args[1:])
	case "comply":
		complyCmd(args[1:])
	case "dev":
		devCmd(args[1:])
	case "route":
		routeCmd(args[1:])
	case "form":
		formCmd(args[1:])
	default:
		gameOver(usageMain)
	}
}

func helpCmd(args []string) {
	if len(args) == 0 {
		fmt.Println(usageMain)
		fmt.Println()
		fmt.Println(helpRun)
		return
	}
	switch args[0] {
	case "run":
		fmt.Println(helpRun)
	case "bench":
		fmt.Println(usageBench)
	case "image":
		fmt.Println(usageImage)
	case "comply":
		fmt.Println(helpComply)
	case "dev":
		fmt.Println(usageDev)
	case "route":
		fmt.Println(usageRoute)
		fmt.Println()
		fmt.Println(usageRouteGet)
		fmt.Println()
		fmt.Println(usageRouteHead)
		fmt.Println()
		fmt.Println(usageRouteList)
		fmt.Println()
		fmt.Println(usageRouteWarc)
	case "form":
		fmt.Println(usageForm)
	default:
		gameOver(usageHelp)
	}
}

func formCmd(args []string) {
	if err := qinternal.RunFormCommand(args); err != nil {
		gameOver("%v", err)
	}
}

func complyCmd(args []string) {
	if err := qinternal.RunComplyCommand(args); err != nil {
		gameOver("%v", err)
	}
}

func readModulePath(path string, opts options) ([]byte, error) {
	var body []byte

	if strings.HasPrefix(path, "https://") {
		resp, err := http.Get(path)
		if err != nil {
			return nil, fmt.Errorf("error fetching URL: %w", err)
		}
		defer func() { _ = resp.Body.Close() }()

		body, err = io.ReadAll(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("error reading response: %w", err)
		}
	} else {
		var err error
		body, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("error reading file: %v", err)
		}
	}

	if opts.verbose {
		moduleDigest := sha256.Sum256(body)
		vlogf(opts, "module %s sha256: %x", path, moduleDigest)
	}

	return body, nil
}

func runCmd(args []string) {
	opts := options{
		contentTypeChecking:    ContentTypeCheckingStrong,
		trustFirstStageContent: true,
	}
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var runVerbose bool
	var inputPath string
	outputPath := "-"
	timeoutMS := 5000
	fs.BoolVar(&runVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&runVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputPath, "i", "", "input file path")
	fs.StringVar(&outputPath, "o", "-", "output file path ('-' for stdout)")
	fs.StringVar(&outputPath, "output", "-", "output file path ('-' for stdout)")
	fs.IntVar(&timeoutMS, "timeout-ms", timeoutMS, "per-run timeout in milliseconds")
	if err := fs.Parse(normalizeRunArgs(args)); err != nil {
		gameOver("%s %v", usageRun, err)
	}
	opts.verbose = opts.verbose || runVerbose

	moduleSpecs, parseErr := parseModuleSpecs(fs.Args(), "run")
	if parseErr != nil {
		gameOver("Invalid run module args: %v", parseErr)
	}
	if len(moduleSpecs) == 0 {
		gameOver(usageRun)
	}
	if timeoutMS <= 0 {
		gameOver("Invalid timeout-ms: %d", timeoutMS)
	}

	var input []byte
	if inputPath == "-" {
		var err error
		input, err = io.ReadAll(os.Stdin)
		if err != nil {
			gameOver("Error reading stdin: %v", err)
		}
	} else if inputPath != "" {
		var err error
		input, err = os.ReadFile(inputPath)
		if err != nil {
			gameOver("Error reading input file: %v", err)
		}
	} else {
		stat, err := os.Stdin.Stat()
		if err != nil {
			gameOver("Error checking stdin: %v", err)
		}

		// Check if stdin is a pipe or file (not a terminal)
		if (stat.Mode() & os.ModeCharDevice) == 0 {
			input, err = io.ReadAll(os.Stdin)
			if err != nil {
				gameOver("Error reading stdin: %v", err)
			}
		}
	}

	if opts.verbose {
		inputDigest := sha256.Sum256(input)
		vlogf(opts, "input sha256: %x", inputDigest)
	}

	start := time.Now()
	defer func() {
		if opts.verbose {
			vlogf(opts, "command took %dms", time.Since(start).Milliseconds())
		}
	}()

	pipeline, err := buildPipelineFromSpecs(context.Background(), moduleSpecs, opts)
	if err != nil {
		gameOver("%v", err)
	}
	defer func() { _ = pipeline.Close(context.Background()) }()

	execCtx := context.Background()
	execCtx, cancel := wasmruntime.WithExecutionTimeout(execCtx, time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()

	initialContent := qinternal.NewRawBytesContentWithType(input, "")
	result, err := pipeline.Process(execCtx, initialContent, 0)
	if err != nil {
		gameOver("%v", err)
	}

	result, outputBytes, err := ensureRawContent(result)
	if err != nil {
		gameOver("%v", err)
	}

	if err := writeRunOutput(result, outputBytes, outputPath, opts); err != nil {
		gameOver("%v", err)
	}
}

// run is retained for test helper compatibility.
func run(args []string) {
	runCmd(args)
}

type benchSample struct {
	total          time.Duration
	instantiation  time.Duration
	run            time.Duration
	memoryBytes    uint64
	inputCapBytes  uint64
	outputCapBytes uint64
}

type benchModuleKind uint8

const (
	benchModuleKindRun benchModuleKind = iota
	benchModuleKindTile
)

type durationStats struct {
	mean   time.Duration
	min    time.Duration
	max    time.Duration
	stddev time.Duration
	p95    time.Duration
}

type benchSummary struct {
	total   durationStats
	run     durationStats
	inst    durationStats
	meanMem uint64
	peakMem uint64
}

func benchCmd(args []string) {
	opts := options{
		contentTypeChecking:    ContentTypeCheckingStrong,
		trustFirstStageContent: true,
	}
	fs := flag.NewFlagSet("bench", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	var benchVerbose bool
	var inputPath string
	benchRuns := 1000
	benchtimeStr := ""
	timeoutMS := 250

	fs.BoolVar(&benchVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&benchVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputPath, "i", "", "input file path ('-' for stdin)")
	fs.IntVar(&benchRuns, "r", benchRuns, "benchmark runs per module")
	fs.StringVar(&benchtimeStr, "benchtime", benchtimeStr, "target measured time per module (e.g. 3s)")
	fs.IntVar(&timeoutMS, "timeout-ms", timeoutMS, "per-run timeout in milliseconds")

	if err := fs.Parse(normalizeBenchArgs(args)); err != nil {
		gameOver("%s %v", usageBench, err)
	}
	opts.verbose = benchVerbose

	modules := fs.Args()
	if inputPath == "" || len(modules) < 1 {
		gameOver(usageBench)
	}
	if benchRuns <= 0 {
		gameOver("Invalid benchmark runs: %d", benchRuns)
	}
	if timeoutMS <= 0 {
		gameOver("Invalid timeout-ms: %d", timeoutMS)
	}
	var benchtime time.Duration
	if benchtimeStr != "" {
		parsed, err := time.ParseDuration(benchtimeStr)
		if err != nil {
			gameOver("Invalid benchtime: %v", err)
		}
		if parsed <= 0 {
			gameOver("Invalid benchtime: must be > 0")
		}
		benchtime = parsed
	}

	var inputBytes []byte
	var err error
	if inputPath == "-" {
		inputBytes, err = io.ReadAll(os.Stdin)
		if err != nil {
			gameOver("Error reading stdin: %v", err)
		}
	} else {
		inputBytes, err = os.ReadFile(inputPath)
		if err != nil {
			gameOver("Error reading input file: %v", err)
		}
	}

	if opts.verbose {
		inputDigest := sha256.Sum256(inputBytes)
		vlogf(opts, "bench input sha256: %x", inputDigest)
	}

	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer func() { _ = runtime.Close(ctx) }()

	moduleCount := len(modules)
	compiled := make([]wazero.CompiledModule, moduleCount)
	moduleKinds := make([]benchModuleKind, moduleCount)
	compileDur := make([]time.Duration, moduleCount)
	moduleSizes := make([]uint64, moduleCount)
	moduleGzipSizes := make([]uint64, moduleCount)
	for i, modulePath := range modules {
		body, err := readModulePath(modulePath, opts)
		if err != nil {
			gameOver("%v", err)
		}
		moduleSizes[i] = uint64(len(body))
		gzipSize, err := gzipSizeBytes(body)
		if err != nil {
			gameOver("Error gzipping module %s: %v", modulePath, err)
		}
		moduleGzipSizes[i] = gzipSize
		start := time.Now()
		cm, err := runtime.CompileModule(ctx, body)
		compileDur[i] = time.Since(start)
		if err != nil {
			gameOver("Wasm module could not be compiled")
		}
		funcs := cm.ExportedFunctions()
		_, hasRun := funcs["run"]
		_, hasTile := funcs["tile_rgba_f32_64x64"]
		switch {
		case hasTile:
			moduleKinds[i] = benchModuleKindTile
		case hasRun:
			moduleKinds[i] = benchModuleKindRun
		default:
			gameOver("bench check failed for %s: Wasm module must export run(i32) -> i32 or tile_rgba_f32_64x64(f32, f32)", modules[i])
		}
		compiled[i] = cm
		defer func() { _ = compiled[i].Close(ctx) }()
	}

	perRunTimeout := time.Duration(timeoutMS) * time.Millisecond
	moduleInputCaps := make([]uint64, moduleCount)
	moduleOutputCaps := make([]uint64, moduleCount)
	firstSample, expected, err := runBenchSampleByKind(ctx, runtime, compiled[0], moduleKinds[0], inputBytes, opts, "bench-0-check", perRunTimeout)
	if err != nil {
		gameOver("bench check failed for %s: %v", modules[0], err)
	}
	moduleInputCaps[0] = firstSample.inputCapBytes
	moduleOutputCaps[0] = firstSample.outputCapBytes
	for i := 1; i < moduleCount; i++ {
		sample, output, err := runBenchSampleByKind(ctx, runtime, compiled[i], moduleKinds[i], inputBytes, opts, fmt.Sprintf("bench-%d-check", i), perRunTimeout)
		if err != nil {
			gameOver("bench check failed for %s: %v", modules[i], err)
		}
		moduleInputCaps[i] = sample.inputCapBytes
		moduleOutputCaps[i] = sample.outputCapBytes
		if mismatch := describeContentMismatch(expected, output); mismatch != "" {
			gameOver("bench mismatch for %s vs %s: %s", modules[i], modules[0], mismatch)
		}
	}

	samples := make([][]benchSample, moduleCount)
	for i := range moduleCount {
		samples[i] = make([]benchSample, 0, benchRuns)
	}
	benchTimeTotals := make([]time.Duration, moduleCount)
	for i := 0; ; i++ {
		if benchtime == 0 && i >= benchRuns {
			break
		}
		startIndex := i % moduleCount
		for j := range moduleCount {
			moduleIndex := (startIndex + j) % moduleCount
			sample, output, err := runBenchSampleByKind(
				ctx,
				runtime,
				compiled[moduleIndex],
				moduleKinds[moduleIndex],
				inputBytes,
				opts,
				fmt.Sprintf("bench-%d-run-%d", moduleIndex, i),
				perRunTimeout,
			)
			if err != nil {
				gameOver("bench run failed for %s (run %d): %v", modules[moduleIndex], i+1, err)
			}
			if mismatch := describeContentMismatch(expected, output); mismatch != "" {
				gameOver("bench output mismatch for %s (run %d): %s", modules[moduleIndex], i+1, mismatch)
			}
			samples[moduleIndex] = append(samples[moduleIndex], sample)
			benchTimeTotals[moduleIndex] += sample.total
		}
		if benchtime > 0 && allDurationsAtLeast(benchTimeTotals, benchtime) {
			break
		}
	}

	summaries := make([]benchSummary, moduleCount)
	for i := range moduleCount {
		summaries[i] = summarizeBench(samples[i])
	}

	digest := sha256.Sum256(expected.bytes)
	if moduleCount == 1 {
		fmt.Printf("bench: baseline output captured\n")
	} else {
		fmt.Printf("bench: outputs match\n")
	}
	fmt.Printf("  encoding: %s\n", encodingName(expected.encoding))
	fmt.Printf("  bytes:    %d\n", len(expected.bytes))
	fmt.Printf("  sha256:   %x\n", digest)
	if benchtime > 0 {
		fmt.Printf("  benchtime target: %s per module\n", benchtime)
	}
	fmt.Printf("  measured: %d runs/module\n", len(samples[0]))
	fmt.Printf("  timeout:  %s per run\n\n", perRunTimeout)

	for i := range moduleCount {
		printBenchBenchmarkReport(
			i+1,
			modules[i],
			moduleSizes[i],
			moduleGzipSizes[i],
			moduleInputCaps[i],
			moduleOutputCaps[i],
			compileDur[i],
			summaries[i],
		)
	}

	if moduleCount > 1 {
		bestIdx := 0
		worstIdx := 0
		lowestPeakMemIdx := 0
		for i := 1; i < moduleCount; i++ {
			if summaries[i].total.mean < summaries[bestIdx].total.mean {
				bestIdx = i
			}
			if summaries[i].total.mean > summaries[worstIdx].total.mean {
				worstIdx = i
			}
			if summaries[i].peakMem < summaries[lowestPeakMemIdx].peakMem {
				lowestPeakMemIdx = i
			}
		}
		fastestMean := summaries[bestIdx].total.mean
		slowestMean := summaries[worstIdx].total.mean
		fmt.Printf("Summary\n")
		fmt.Printf("  fastest: %q (mean total time %s)\n", modules[bestIdx], fastestMean)
		if fastestMean > 0 && slowestMean > 0 && bestIdx != worstIdx {
			ratio := float64(slowestMean) / float64(fastestMean)
			fmt.Printf("  speedup vs slowest: %.2fx over %q\n", ratio, modules[worstIdx])
		}
		fmt.Printf("  lowest peak memory: %q (peak %s, mean %s)\n", modules[lowestPeakMemIdx], formatBytesIEC(summaries[lowestPeakMemIdx].peakMem), formatBytesIEC(summaries[lowestPeakMemIdx].meanMem))
	}
}

func runBenchSample(
	parent context.Context,
	runtime wazero.Runtime,
	compiled wazero.CompiledModule,
	inputBytes []byte,
	opts options,
	moduleName string,
	timeout time.Duration,
) (benchSample, contentData, error) {
	ctx := parent
	cancel := func() {}
	if timeout > 0 {
		ctxWithTimeout, cancelWithTimeout := wasmruntime.WithExecutionTimeout(parent, timeout)
		ctx = ctxWithTimeout
		cancel = cancelWithTimeout
	}
	defer cancel()

	exec, err := executeModuleWithInput(ctx, runtime, compiled, inputBytes, opts, moduleName, nil, "", opts.trustFirstStageContent)
	if err != nil {
		return benchSample{}, contentData{}, err
	}
	sample := benchSample{
		total:          exec.total,
		instantiation:  exec.instantiation,
		run:            exec.run,
		memoryBytes:    exec.memoryBytes,
		inputCapBytes:  exec.inputCapBytes,
		outputCapBytes: exec.outputCapBytes,
	}
	return sample, exec.output, nil
}

func runBenchSampleByKind(
	parent context.Context,
	runtime wazero.Runtime,
	compiled wazero.CompiledModule,
	kind benchModuleKind,
	inputBytes []byte,
	opts options,
	moduleName string,
	timeout time.Duration,
) (benchSample, contentData, error) {
	switch kind {
	case benchModuleKindRun:
		return runBenchSample(parent, runtime, compiled, inputBytes, opts, moduleName, timeout)
	case benchModuleKindTile:
		return runBenchTileSample(parent, runtime, compiled, inputBytes, moduleName, timeout)
	default:
		return benchSample{}, contentData{}, errors.New("unknown bench module kind")
	}
}

func runBenchTileSample(
	parent context.Context,
	runtime wazero.Runtime,
	compiled wazero.CompiledModule,
	inputBytes []byte,
	moduleName string,
	timeout time.Duration,
) (benchSample, contentData, error) {
	ctx := parent
	cancel := func() {}
	if timeout > 0 {
		ctxWithTimeout, cancelWithTimeout := wasmruntime.WithExecutionTimeout(parent, timeout)
		ctx = ctxWithTimeout
		cancel = cancelWithTimeout
	}
	defer cancel()

	inputRGBA, err := decodeBMP(inputBytes)
	if err != nil {
		return benchSample{}, contentData{}, fmt.Errorf("tile bench input must be BMP: %w", err)
	}

	start := time.Now()
	outputRGBA, instDurations, stageDurations, err := runTileStagesCompiled(
		ctx,
		runtime,
		[]wazero.CompiledModule{compiled},
		inputRGBA,
		moduleName,
		0,
	)
	total := time.Since(start)
	if err != nil {
		return benchSample{}, contentData{}, err
	}

	outBytes, err := encodeBMP(outputRGBA)
	if err != nil {
		return benchSample{}, contentData{}, err
	}

	sample := benchSample{
		total: total,
	}
	if len(instDurations) > 0 {
		sample.instantiation = instDurations[0]
	}
	if len(stageDurations) > 0 {
		sample.run = stageDurations[0]
	}
	return sample, contentData{bytes: outBytes, encoding: dataEncodingRaw}, nil
}

func summarizeBench(samples []benchSample) benchSummary {
	totalValues := make([]time.Duration, len(samples))
	runValues := make([]time.Duration, len(samples))
	instValues := make([]time.Duration, len(samples))
	memValues := make([]uint64, len(samples))

	for i, sample := range samples {
		totalValues[i] = sample.total
		runValues[i] = sample.run
		instValues[i] = sample.instantiation
		memValues[i] = sample.memoryBytes
	}

	meanMem, peakMem := summarizeMemory(memValues)
	return benchSummary{
		total:   summarizeDurations(totalValues),
		run:     summarizeDurations(runValues),
		inst:    summarizeDurations(instValues),
		meanMem: meanMem,
		peakMem: peakMem,
	}
}

func summarizeDurations(values []time.Duration) durationStats {
	if len(values) == 0 {
		return durationStats{}
	}

	n := len(values)
	ns := make([]float64, n)
	sorted := make([]int64, n)
	var sum float64
	for i, value := range values {
		x := float64(value.Nanoseconds())
		ns[i] = x
		sum += x
		sorted[i] = value.Nanoseconds()
	}
	slices.Sort(sorted)

	mean := sum / float64(n)
	var variance float64
	for _, x := range ns {
		delta := x - mean
		variance += delta * delta
	}
	variance /= float64(n)

	p95Index := max(int(math.Ceil(0.95*float64(n)))-1, 0)
	if p95Index >= n {
		p95Index = n - 1
	}

	return durationStats{
		mean:   time.Duration(int64(math.Round(mean))),
		min:    time.Duration(sorted[0]),
		max:    time.Duration(sorted[n-1]),
		stddev: time.Duration(int64(math.Round(math.Sqrt(variance)))),
		p95:    time.Duration(sorted[p95Index]),
	}
}

func summarizeMemory(values []uint64) (mean, peak uint64) {
	if len(values) == 0 {
		return 0, 0
	}
	var sum float64
	for _, v := range values {
		sum += float64(v)
		if v > peak {
			peak = v
		}
	}
	return uint64(math.Round(sum / float64(len(values)))), peak
}

func allDurationsAtLeast(values []time.Duration, threshold time.Duration) bool {
	for _, value := range values {
		if value < threshold {
			return false
		}
	}
	return true
}

func gzipSizeBytes(data []byte) (uint64, error) {
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return 0, err
	}
	if _, err := zw.Write(data); err != nil {
		_ = zw.Close()
		return 0, err
	}
	if err := zw.Close(); err != nil {
		return 0, err
	}
	return uint64(buf.Len()), nil
}

func formatBytesIEC(bytes uint64) string {
	const unit = uint64(1024)
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := unit, 0
	for n := bytes / unit; n >= unit && exp < 5; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

func printBenchBenchmarkReport(index int, modulePath string, binarySize uint64, gzipSize uint64, inputCapBytes uint64, outputCapBytes uint64, compileDuration time.Duration, summary benchSummary) {
	fmt.Printf("Benchmark %d: %s\n", index, modulePath)
	fmt.Printf("  Time (mean ± stddev): %s ± %s [min: %s, p95: %s, max: %s]\n",
		summary.total.mean,
		summary.total.stddev,
		summary.total.min,
		summary.total.p95,
		summary.total.max,
	)
	fmt.Printf("  Breakdown: run mean %s, instantiation mean %s, compile %s\n",
		summary.run.mean,
		summary.inst.mean,
		compileDuration,
	)
	fmt.Printf("  Memory allocated: mean %s, peak %s\n", formatBytesIEC(summary.meanMem), formatBytesIEC(summary.peakMem))
	fmt.Printf("  Capacity: input %s, output %s\n", formatBytesIEC(inputCapBytes), formatBytesIEC(outputCapBytes))
	fmt.Printf("  Binary size: %d bytes, gzip %d bytes\n", binarySize, gzipSize)
	fmt.Printf("\n")
}

func parseModuleSpecs(args []string, commandName string) ([]moduleSpec, error) {
	specs := make([]moduleSpec, 0, len(args))
	for _, arg := range args {
		if strings.HasPrefix(arg, "?") {
			if len(specs) == 0 {
				return nil, fmt.Errorf("%s uniform query %q must follow a wasm module path", commandName, arg)
			}
			if len(arg) == 1 {
				return nil, fmt.Errorf("%s uniform query must not be empty", commandName)
			}
			values, err := url.ParseQuery(arg[1:])
			if err != nil {
				return nil, fmt.Errorf("invalid %s uniform query %q: %w", commandName, arg, err)
			}
			if len(values) == 0 {
				return nil, fmt.Errorf("%s uniform query %q must contain key=value pairs", commandName, arg)
			}
			last := &specs[len(specs)-1]
			for key, vals := range values {
				if key == "" {
					return nil, fmt.Errorf("invalid %s uniform query %q: empty key", commandName, arg)
				}
				if len(vals) == 0 {
					return nil, fmt.Errorf("invalid %s uniform query %q: missing value for %q", commandName, arg, key)
				}
				last.uniforms[key] = vals[len(vals)-1]
			}
			continue
		}

		specs = append(specs, moduleSpec{
			path:     arg,
			uniforms: make(map[string]string),
		})
	}
	return specs, nil
}

func describeContentMismatch(expected, actual contentData) string {
	if expected.encoding != actual.encoding {
		return fmt.Sprintf("encoding differs (expected %s, actual %s)", encodingName(expected.encoding), encodingName(actual.encoding))
	}
	if bytes.Equal(expected.bytes, actual.bytes) {
		return ""
	}
	diffAt := firstDiffIndex(expected.bytes, actual.bytes)
	expSum := sha256.Sum256(expected.bytes)
	actSum := sha256.Sum256(actual.bytes)
	if diffAt >= 0 {
		return fmt.Sprintf(
			"output differs at byte %d (expected len=%d sha256=%x, actual len=%d sha256=%x)",
			diffAt,
			len(expected.bytes),
			expSum,
			len(actual.bytes),
			actSum,
		)
	}
	return fmt.Sprintf(
		"output size differs (expected size=%d sha256=%x, actual size=%d sha256=%x)",
		len(expected.bytes),
		expSum,
		len(actual.bytes),
		actSum,
	)
}

func firstDiffIndex(a, b []byte) int {
	limit := min(len(b), len(a))
	for i := range limit {
		if a[i] != b[i] {
			return i
		}
	}
	if len(a) != len(b) {
		return limit
	}
	return -1
}

func encodingName(encoding dataEncoding) string {
	switch encoding {
	case dataEncodingRaw:
		return "raw"
	case dataEncodingUTF8:
		return "utf8"
	case dataEncodingArrayI32:
		return "i32[]"
	default:
		return fmt.Sprintf("unknown(%d)", encoding)
	}
}

func loadTileStage(ctx context.Context, mod api.Module) (tileStage, error) {
	tileFunc := mod.ExportedFunction("tile_rgba_f32_64x64")
	if tileFunc == nil {
		return tileStage{}, errors.New("wasm module must export tile_rgba_f32_64x64")
	}
	uniformFunc := mod.ExportedFunction("uniform_set_width_and_height")
	haloFunc := mod.ExportedFunction("calculate_halo_px")
	mem := mod.Memory()
	inputPtrValue, ok, err := getExportedValue(ctx, mod, "input_ptr")
	if err != nil {
		return tileStage{}, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !ok {
		return tileStage{}, errors.New("wasm module must export input_ptr as global or function")
	}
	inputCap, ok, err := getExportedValue(ctx, mod, "input_bytes_cap")
	if err != nil {
		return tileStage{}, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !ok {
		return tileStage{}, errors.New("wasm module must export input_bytes_cap as global or function")
	}
	return tileStage{
		mod:         mod,
		mem:         mem,
		tileFunc:    tileFunc,
		inputPtr:    uint32(inputPtrValue),
		uniformFunc: uniformFunc,
		haloFunc:    haloFunc,
		inputCap:    inputCap,
	}, nil
}

func closeTileStages(ctx context.Context, stages []tileStage) {
	for _, stage := range stages {
		if stage.mod != nil {
			_ = stage.mod.Close(ctx)
		}
	}
}

func runTileStages(ctx context.Context, stages []tileStage, inputRGBA *image.RGBA) (*image.RGBA, []time.Duration, error) {
	if len(stages) == 0 {
		return inputRGBA, []time.Duration{}, nil
	}

	bounds := inputRGBA.Bounds()
	width := bounds.Dx()
	height := bounds.Dy()
	outputRGBA := image.NewRGBA(bounds)

	for i := range stages {
		stage := &stages[i]
		if stage.uniformFunc != nil {
			if _, err := stage.uniformFunc.Call(
				ctx,
				api.EncodeF32(float32(width)),
				api.EncodeF32(float32(height)),
			); err != nil {
				return nil, nil, fmt.Errorf("error running uniform_set_width_and_height: %v", err)
			}
		}
		if stage.haloFunc != nil {
			values, err := stage.haloFunc.Call(ctx)
			if err != nil {
				return nil, nil, fmt.Errorf("error running calculate_halo_px: %v", err)
			}
			if len(values) > 0 {
				stage.haloPx = int(int32(values[0]))
			}
		}
		if stage.haloPx < 0 {
			stage.haloPx = 0
		}
		stage.tileSpan = tileSize + stage.haloPx*2
		tileF32Size := uint64(stage.tileSpan) * uint64(stage.tileSpan) * 4 * 4
		if tileF32Size > stage.inputCap {
			return nil, nil, errors.New("tile buffer exceeds module input_bytes_cap")
		}
	}

	const inv255 = 1.0 / 255.0
	useHalo := false
	for _, stage := range stages {
		if stage.haloPx > 0 {
			useHalo = true
			break
		}
	}

	stageDurations := make([]time.Duration, len(stages))

	if useHalo {
		floatSrc := make([]float32, width*height*4)
		floatDst := make([]float32, len(floatSrc))
		pix := inputRGBA.Pix
		stride := inputRGBA.Stride
		for y := range height {
			srcRow := y * stride
			dstRow := y * width * 4
			for x := range width {
				s := srcRow + x*4
				d := dstRow + x*4
				floatSrc[d] = float32(pix[s]) * inv255
				floatSrc[d+1] = float32(pix[s+1]) * inv255
				floatSrc[d+2] = float32(pix[s+2]) * inv255
				floatSrc[d+3] = float32(pix[s+3]) * inv255
			}
		}

		for stageIndex := range stages {
			stageStart := time.Now()
			stage := &stages[stageIndex]
			halo := stage.haloPx
			tileSpan := stage.tileSpan
			tileFloats := tileSpan * tileSpan * 4
			tileF32 := make([]float32, tileFloats)
			tileBytes := unsafe.Slice((*byte)(unsafe.Pointer(&tileF32[0])), len(tileF32)*4)

			for y := 0; y < height; y += tileSize {
				tileH := tileSize
				if y+tileH > height {
					tileH = height - y
				}
				for x := 0; x < width; x += tileSize {
					tileW := tileSize
					if x+tileW > width {
						tileW = width - x
					}
					for row := range tileSpan {
						srcY := y + row - halo
						if srcY < 0 {
							srcY = 0
						} else if srcY >= height {
							srcY = height - 1
						}
						srcRow := srcY * width * 4
						dstRow := row * tileSpan * 4
						for col := range tileSpan {
							srcX := x + col - halo
							if srcX < 0 {
								srcX = 0
							} else if srcX >= width {
								srcX = width - 1
							}
							s := srcRow + srcX*4
							d := dstRow + col*4
							tileF32[d] = floatSrc[s]
							tileF32[d+1] = floatSrc[s+1]
							tileF32[d+2] = floatSrc[s+2]
							tileF32[d+3] = floatSrc[s+3]
						}
					}

					if !stage.mem.Write(stage.inputPtr, tileBytes) {
						return nil, nil, errors.New("could not write tile to wasm memory")
					}
					tileX := x - halo
					tileY := y - halo
					if _, err := stage.tileFunc.Call(
						ctx,
						api.EncodeF32(float32(tileX)),
						api.EncodeF32(float32(tileY)),
					); err != nil {
						return nil, nil, fmt.Errorf("error running tile_rgba_f32_64x64: %w", wasmruntime.HumanizeExecutionError(ctx, err))
					}
					tileOutBytes, ok := stage.mem.Read(stage.inputPtr, uint32(len(tileBytes)))
					if !ok {
						return nil, nil, errors.New("could not read tile from wasm memory")
					}
					copy(tileBytes, tileOutBytes)

					srcBase := (halo*tileSpan + halo) * 4
					for row := 0; row < tileH; row++ {
						src := srcBase + row*tileSpan*4
						dst := ((y + row) * width) * 4
						for col := 0; col < tileW; col++ {
							s := src + col*4
							d := dst + (x+col)*4
							floatDst[d] = tileF32[s]
							floatDst[d+1] = tileF32[s+1]
							floatDst[d+2] = tileF32[s+2]
							floatDst[d+3] = tileF32[s+3]
						}
					}
				}
			}

			floatSrc, floatDst = floatDst, floatSrc
			stageDurations[stageIndex] = time.Since(stageStart)
		}

		outPix := outputRGBA.Pix
		outStride := outputRGBA.Stride
		for y := range height {
			srcRow := y * width * 4
			dstRow := y * outStride
			for x := range width {
				s := srcRow + x*4
				d := dstRow + x*4
				v := floatSrc[s]
				if v <= 0 {
					outPix[d] = 0
				} else if v >= 1 {
					outPix[d] = 255
				} else {
					outPix[d] = uint8(v*255 + 0.5)
				}
				v = floatSrc[s+1]
				if v <= 0 {
					outPix[d+1] = 0
				} else if v >= 1 {
					outPix[d+1] = 255
				} else {
					outPix[d+1] = uint8(v*255 + 0.5)
				}
				v = floatSrc[s+2]
				if v <= 0 {
					outPix[d+2] = 0
				} else if v >= 1 {
					outPix[d+2] = 255
				} else {
					outPix[d+2] = uint8(v*255 + 0.5)
				}
				v = floatSrc[s+3]
				if v <= 0 {
					outPix[d+3] = 0
				} else if v >= 1 {
					outPix[d+3] = 255
				} else {
					outPix[d+3] = uint8(v*255 + 0.5)
				}
			}
		}
	} else {
		pix := inputRGBA.Pix
		stride := inputRGBA.Stride
		outputPix := outputRGBA.Pix
		outputStride := outputRGBA.Stride
		tileF32 := make([]float32, tileSize*tileSize*4)
		tileBytes := unsafe.Slice((*byte)(unsafe.Pointer(&tileF32[0])), len(tileF32)*4)
		for y := 0; y < height; y += tileSize {
			tileH := tileSize
			if y+tileH > height {
				tileH = height - y
			}
			rowBase := y * stride
			for x := 0; x < width; x += tileSize {
				tileW := tileSize
				if x+tileW > width {
					tileW = width - x
				}
				srcRow := rowBase + x*4
				if tileW != tileSize || tileH != tileSize {
					clear(tileF32)
				}
				for row := 0; row < tileH; row++ {
					src := srcRow + row*stride
					dst := row * tileSize * 4
					for col := 0; col < tileW; col++ {
						s := src + col*4
						d := dst + col*4
						tileF32[d] = float32(pix[s]) * inv255
						tileF32[d+1] = float32(pix[s+1]) * inv255
						tileF32[d+2] = float32(pix[s+2]) * inv255
						tileF32[d+3] = float32(pix[s+3]) * inv255
					}
				}
				for stageIndex := range stages {
					stage := &stages[stageIndex]
					stageStart := time.Now()
					if !stage.mem.Write(stage.inputPtr, tileBytes) {
						return nil, nil, errors.New("could not write tile to wasm memory")
					}
					if _, err := stage.tileFunc.Call(
						ctx,
						api.EncodeF32(float32(x)),
						api.EncodeF32(float32(y)),
					); err != nil {
						return nil, nil, fmt.Errorf("error running tile_rgba_f32_64x64: %w", wasmruntime.HumanizeExecutionError(ctx, err))
					}
					tileOutBytes, ok := stage.mem.Read(stage.inputPtr, uint32(len(tileBytes)))
					if !ok {
						return nil, nil, errors.New("could not read tile from wasm memory")
					}
					copy(tileBytes, tileOutBytes)
					stageDurations[stageIndex] += time.Since(stageStart)
				}
				tileOutF32 := tileF32
				for row := 0; row < tileH; row++ {
					src := row * tileSize * 4
					dst := (y+row)*outputStride + x*4
					for col := 0; col < tileW; col++ {
						s := src + col*4
						d := dst + col*4
						v := tileOutF32[s]
						if v <= 0 {
							outputPix[d] = 0
						} else if v >= 1 {
							outputPix[d] = 255
						} else {
							outputPix[d] = uint8(v*255 + 0.5)
						}
						v = tileOutF32[s+1]
						if v <= 0 {
							outputPix[d+1] = 0
						} else if v >= 1 {
							outputPix[d+1] = 255
						} else {
							outputPix[d+1] = uint8(v*255 + 0.5)
						}
						v = tileOutF32[s+2]
						if v <= 0 {
							outputPix[d+2] = 0
						} else if v >= 1 {
							outputPix[d+2] = 255
						} else {
							outputPix[d+2] = uint8(v*255 + 0.5)
						}
						v = tileOutF32[s+3]
						if v <= 0 {
							outputPix[d+3] = 0
						} else if v >= 1 {
							outputPix[d+3] = 255
						} else {
							outputPix[d+3] = uint8(v*255 + 0.5)
						}
					}
				}
			}
		}
	}

	return outputRGBA, stageDurations, nil
}

func runTileStagesCompiled(ctx context.Context, runtime wazero.Runtime, compiled []wazero.CompiledModule, inputRGBA *image.RGBA, moduleNamePrefix string, stageOffset int) (*image.RGBA, []time.Duration, []time.Duration, error) {
	stages := make([]tileStage, len(compiled))
	instDurations := make([]time.Duration, len(compiled))

	for i, cm := range compiled {
		instStart := time.Now()
		mod, err := runtime.InstantiateModule(ctx, cm, wazero.NewModuleConfig().WithName(fmt.Sprintf("%s-%d", moduleNamePrefix, stageOffset+i)))
		instDurations[i] = time.Since(instStart)
		if err != nil {
			closeTileStages(ctx, stages)
			return nil, instDurations, nil, errors.New("wasm module could not be instantiated")
		}
		stage, err := loadTileStage(ctx, mod)
		if err != nil {
			closeTileStages(ctx, stages)
			return nil, instDurations, nil, err
		}
		stages[i] = stage
	}
	defer closeTileStages(ctx, stages)

	outputRGBA, stageDurations, err := runTileStages(ctx, stages, inputRGBA)
	if err != nil {
		return nil, instDurations, stageDurations, err
	}
	return outputRGBA, instDurations, stageDurations, nil
}

func parseUniformInt(value string, bitSize int) (int64, error) {
	base := 10
	raw := value

	if len(value) >= 2 && value[0] == '0' && (value[1] == 'x' || value[1] == 'X') {
		base = 16
		raw = value[2:]
	} else if len(value) >= 3 && (value[0] == '+' || value[0] == '-') && value[1] == '0' && (value[2] == 'x' || value[2] == 'X') {
		base = 16
		raw = value[:1] + value[3:]
	}

	return strconv.ParseInt(raw, base, bitSize)
}

func parseUniformHexUint(value string, bitSize int) (uint64, bool, error) {
	if len(value) < 2 || value[0] != '0' || (value[1] != 'x' && value[1] != 'X') {
		return 0, false, nil
	}

	parsed, err := strconv.ParseUint(value[2:], 16, bitSize)
	if err != nil {
		return 0, true, err
	}
	return parsed, true, nil
}

func applyModuleUniforms(ctx context.Context, mod api.Module, uniforms map[string]string) error {
	if len(uniforms) == 0 {
		return nil
	}
	defs := mod.ExportedFunctionDefinitions()
	keys := make([]string, 0, len(uniforms))
	for key := range uniforms {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		fnName := "uniform_set_" + key
		fn := mod.ExportedFunction(fnName)
		if fn == nil {
			return fmt.Errorf("wasm module does not export %s for query key %q", fnName, key)
		}
		def, ok := defs[fnName]
		if !ok {
			return fmt.Errorf("wasm module is missing function definition for %s", fnName)
		}
		paramTypes := def.ParamTypes()
		if len(paramTypes) != 1 {
			return fmt.Errorf("%s must accept exactly one argument", fnName)
		}
		value := uniforms[key]

		var args [1]uint64
		switch paramTypes[0] {
		case api.ValueTypeF32:
			parsed, err := strconv.ParseFloat(value, 32)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected f32)", value, fnName)
			}
			args[0] = api.EncodeF32(float32(parsed))
		case api.ValueTypeF64:
			parsed, err := strconv.ParseFloat(value, 64)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected f64)", value, fnName)
			}
			args[0] = api.EncodeF64(parsed)
		case api.ValueTypeI32:
			parsedHex, isHex, err := parseUniformHexUint(value, 32)
			if isHex {
				if err != nil {
					return fmt.Errorf("invalid value %q for %s (expected i32)", value, fnName)
				}
				args[0] = uint64(uint32(parsedHex))
				break
			}
			parsed, err := parseUniformInt(value, 32)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected i32)", value, fnName)
			}
			args[0] = uint64(uint32(int32(parsed)))
		case api.ValueTypeI64:
			parsedHex, isHex, err := parseUniformHexUint(value, 64)
			if isHex {
				if err != nil {
					return fmt.Errorf("invalid value %q for %s (expected i64)", value, fnName)
				}
				args[0] = parsedHex
				break
			}
			parsed, err := parseUniformInt(value, 64)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected i64)", value, fnName)
			}
			args[0] = uint64(parsed)
		default:
			return fmt.Errorf("%s has unsupported parameter type", fnName)
		}

		if _, err := fn.Call(ctx, args[0]); err != nil {
			return fmt.Errorf("error running %s(%s): %w", fnName, value, wasmruntime.HumanizeExecutionError(ctx, err))
		}
	}
	return nil
}

func decodeBMP(input []byte) (*image.RGBA, error) {
	if len(input) < 54 {
		return nil, errors.New("BMP input too small")
	}
	if input[0] != 'B' || input[1] != 'M' {
		return nil, errors.New("input is not a BMP file")
	}

	dataOffset := int(binary.LittleEndian.Uint32(input[10:14]))
	dibSize := int(binary.LittleEndian.Uint32(input[14:18]))
	if dibSize < 40 {
		return nil, errors.New("unsupported BMP DIB header")
	}
	width := int32(binary.LittleEndian.Uint32(input[18:22]))
	height := int32(binary.LittleEndian.Uint32(input[22:26]))
	planes := binary.LittleEndian.Uint16(input[26:28])
	bpp := binary.LittleEndian.Uint16(input[28:30])
	compression := binary.LittleEndian.Uint32(input[30:34])

	if width <= 0 || height == 0 {
		return nil, errors.New("unsupported bmp dimensions")
	}
	if planes != 1 {
		return nil, errors.New("unsupported bmp planes")
	}
	if compression != 0 {
		return nil, errors.New("unsupported bmp compression")
	}
	if bpp != 24 && bpp != 32 {
		return nil, errors.New("unsupported bmp bit depth")
	}

	topDown := false
	absHeight := int(height)
	if height < 0 {
		topDown = true
		absHeight = -absHeight
	}
	absWidth := int(width)
	if absWidth <= 0 || absHeight <= 0 {
		return nil, errors.New("unsupported bmp dimensions")
	}

	bytesPerPixel := int(bpp / 8)
	rowStride := absWidth * bytesPerPixel
	if bpp == 24 {
		if rem := rowStride % 4; rem != 0 {
			rowStride += 4 - rem
		}
	}

	if dataOffset < 0 || dataOffset > len(input) {
		return nil, errors.New("invalid bmp data offset")
	}
	if dataOffset+rowStride*absHeight > len(input) {
		return nil, errors.New("bmp pixel data out of range")
	}

	img := image.NewRGBA(image.Rect(0, 0, absWidth, absHeight))
	for y := 0; y < absHeight; y++ {
		srcY := y
		if !topDown {
			srcY = absHeight - 1 - y
		}
		srcRow := dataOffset + srcY*rowStride
		for x := range absWidth {
			s := srcRow + x*bytesPerPixel
			b := input[s]
			g := input[s+1]
			r := input[s+2]
			a := byte(0xFF)
			if bytesPerPixel == 4 {
				a = input[s+3]
			}
			d := img.PixOffset(x, y)
			img.Pix[d] = r
			img.Pix[d+1] = g
			img.Pix[d+2] = b
			img.Pix[d+3] = a
		}
	}

	return img, nil
}

func encodeBMP(img *image.RGBA) ([]byte, error) {
	bounds := img.Bounds()
	width := bounds.Dx()
	height := bounds.Dy()
	if width <= 0 || height <= 0 {
		return nil, errors.New("invalid bmp image size")
	}

	rowStride := width * 4
	dataSize := rowStride * height
	fileSize := 14 + 40 + dataSize
	buf := make([]byte, fileSize)
	buf[0] = 'B'
	buf[1] = 'M'
	binary.LittleEndian.PutUint32(buf[2:], uint32(fileSize))
	binary.LittleEndian.PutUint32(buf[10:], 54)
	binary.LittleEndian.PutUint32(buf[14:], 40)
	binary.LittleEndian.PutUint32(buf[18:], uint32(width))
	binary.LittleEndian.PutUint32(buf[22:], uint32(height))
	binary.LittleEndian.PutUint16(buf[26:], 1)
	binary.LittleEndian.PutUint16(buf[28:], 32)
	binary.LittleEndian.PutUint32(buf[30:], 0)
	binary.LittleEndian.PutUint32(buf[34:], uint32(dataSize))

	for y := range height {
		srcY := height - 1 - y
		for x := range width {
			s := img.PixOffset(bounds.Min.X+x, bounds.Min.Y+srcY)
			d := 54 + y*rowStride + x*4
			buf[d] = img.Pix[s+2]
			buf[d+1] = img.Pix[s+1]
			buf[d+2] = img.Pix[s]
			buf[d+3] = img.Pix[s+3]
		}
	}

	return buf, nil
}

func imageCmd(args []string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingNone,
	}
	var inputImagePath string
	var outputImagePath string
	timeoutMS := 4000
	fs := flag.NewFlagSet("image", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var imageVerbose bool
	fs.BoolVar(&imageVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&imageVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputImagePath, "i", "", "input image path")
	fs.StringVar(&outputImagePath, "o", "", "output image path")
	fs.IntVar(&timeoutMS, "timeout-ms", timeoutMS, "module execution timeout in milliseconds")
	if err := fs.Parse(normalizeImageArgs(args)); err != nil {
		gameOver("%s %v", usageImage, err)
	}
	opts.verbose = opts.verbose || imageVerbose
	moduleSpecs, parseErr := parseModuleSpecs(fs.Args(), "image")
	if parseErr != nil {
		gameOver("Invalid image module args: %v", parseErr)
	}
	if len(moduleSpecs) == 0 || inputImagePath == "" || outputImagePath == "" {
		gameOver(usageImage)
	}
	if timeoutMS <= 0 {
		gameOver("Invalid timeout-ms: %d", timeoutMS)
	}

	moduleBodies := make([][]byte, len(moduleSpecs))
	for i, spec := range moduleSpecs {
		body, err := readModulePath(spec.path, opts)
		if err != nil {
			gameOver("%v", err)
		}
		moduleBodies[i] = body
	}

	baseCtx := context.Background()

	var inputImageBytes []byte
	var err error
	if inputImagePath == "-" {
		inputImageBytes, err = io.ReadAll(os.Stdin)
		if err != nil {
			gameOver("Error reading image stdin: %v", err)
		}
	} else {
		inputImageBytes, err = os.ReadFile(inputImagePath)
		if err != nil {
			gameOver("Error reading image file: %v", err)
		}
	}
	decodeImage := func(r io.Reader) (image.Image, error) {
		img, _, err := image.Decode(r)
		return img, err
	}
	if len(inputImageBytes) >= 8 && bytes.Equal(inputImageBytes[:8], []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a}) {
		decodeImage = png.Decode
	}
	inputImage, err := decodeImage(bytes.NewReader(inputImageBytes))
	if err != nil {
		gameOver("Error decoding image file: %v", err)
	}
	inputRGBA, ok := inputImage.(*image.RGBA)
	if !ok {
		bounds := inputImage.Bounds()
		inputRGBA = image.NewRGBA(bounds)
		draw.Draw(inputRGBA, bounds, inputImage, bounds.Min, draw.Src)
	}

	start := time.Now()
	defer func() {
		if opts.verbose {
			vlogf(opts, "command took %dms", time.Since(start).Milliseconds())
		}
	}()

	execCtx, cancel := wasmruntime.WithExecutionTimeout(baseCtx, time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()

	r := wasmruntime.New(execCtx)
	defer func() { _ = r.Close(baseCtx) }()

	stages := make([]tileStage, len(moduleBodies))
	for i, body := range moduleBodies {
		mod, err := r.InstantiateWithConfig(execCtx, body, wazero.NewModuleConfig().WithName(fmt.Sprintf("image-%d", i)))
		if err != nil {
			gameOver("Wasm module could not be compiled")
		}
		if err := applyModuleUniforms(execCtx, mod, moduleSpecs[i].uniforms); err != nil {
			gameOver("%v", err)
		}
		stage, err := loadTileStage(execCtx, mod)
		if err != nil {
			gameOver("%v", err)
		}
		stages[i] = stage
	}
	defer closeTileStages(baseCtx, stages)

	finalRGBA, _, err := runTileStages(execCtx, stages, inputRGBA)
	if err != nil {
		gameOver("%v", err)
	}

	encodedImageBytes, err := encodeImageForOutputPath(finalRGBA, outputImagePath)
	if err != nil {
		gameOver("Error encoding output image: %v", err)
	}
	if err := os.WriteFile(outputImagePath, encodedImageBytes, 0o644); err != nil {
		gameOver("Error writing output image file: %v", err)
	}
}

// getExportedValue tries to get a value from either a global or a function.
// The bool return indicates whether the export exists.
func getExportedValue(ctx context.Context, mod api.Module, name string) (uint64, bool, error) {
	// Try global first
	if global := mod.ExportedGlobal(name); global != nil {
		return global.Get(), true, nil
	}

	// Try function if global doesn't exist
	if fn := mod.ExportedFunction(name); fn != nil {
		result, err := fn.Call(ctx)
		if err != nil {
			return 0, true, fmt.Errorf("%s() call failed: %w", name, err)
		}
		if len(result) != 1 {
			return 0, true, fmt.Errorf("%s() returned %d values, want 1", name, len(result))
		}
		return result[0], true, nil
	}

	return 0, false, nil
}

func normalizeIncomingContentType(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	mediaType, _, err := mime.ParseMediaType(value)
	if err == nil && mediaType != "" {
		return strings.ToLower(mediaType)
	}
	if cut := strings.IndexByte(value, ';'); cut != -1 {
		value = strings.TrimSpace(value[:cut])
	}
	return strings.ToLower(value)
}

func normalizeDeclaredContentType(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New("content type is empty")
	}
	if strings.Contains(value, ",") {
		return "", errors.New("content type must contain exactly one MIME type")
	}
	mediaType, params, err := mime.ParseMediaType(value)
	if err != nil {
		return "", fmt.Errorf("invalid content type %q: %w", value, err)
	}
	if mediaType == "" {
		return "", errors.New("content type is empty")
	}
	if len(params) > 0 {
		return "", fmt.Errorf("content type %q must not include parameters", value)
	}
	if strings.Contains(mediaType, "*") {
		return "", fmt.Errorf("content type %q must not include media ranges", value)
	}
	return strings.ToLower(mediaType), nil
}

func readOptionalModuleContentType(ctx context.Context, mod api.Module, prefix string) (string, bool, error) {
	ptrName := prefix + "_content_type_ptr"
	sizeName := prefix + "_content_type_size"

	ptr, hasPtr, err := getExportedValue(ctx, mod, ptrName)
	if err != nil {
		return "", false, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	size, hasSize, err := getExportedValue(ctx, mod, sizeName)
	if err != nil {
		return "", false, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if hasPtr != hasSize {
		return "", false, fmt.Errorf("module must export both %s and %s together", ptrName, sizeName)
	}
	if !hasPtr {
		return "", false, nil
	}
	if size == 0 {
		return "", false, fmt.Errorf("module export %s must be non-empty when present", sizeName)
	}

	mem := mod.Memory()
	raw, ok := mem.Read(uint32(ptr), uint32(size))
	if !ok {
		return "", false, fmt.Errorf("failed to read %s bytes from module memory", prefix)
	}
	mediaType, err := normalizeDeclaredContentType(string(raw))
	if err != nil {
		return "", false, fmt.Errorf("invalid %s content type metadata: %w", prefix, err)
	}
	return mediaType, true, nil
}

type moduleExecutionResult struct {
	output            contentData
	outputContentType string
	instantiation     time.Duration
	run               time.Duration
	total             time.Duration
	memoryBytes       uint64
	inputCapBytes     uint64
	outputCapBytes    uint64
}

func executeModuleWithInput(
	ctx context.Context,
	runtime wazero.Runtime,
	compiled wazero.CompiledModule,
	inputBytes []byte,
	opts options,
	moduleName string,
	uniforms map[string]string,
	incomingContentType string,
	allowMissingInputContentType bool,
) (exec moduleExecutionResult, returnErr error) {
	totalStart := time.Now()
	defer func() {
		exec.total = time.Since(totalStart)
	}()

	instStart := time.Now()
	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName(moduleName))
	if err != nil {
		returnErr = errors.New("wasm module could not be instantiated")
		return
	}
	defer func() { _ = mod.Close(ctx) }()
	exec.instantiation = time.Since(instStart)

	if err := applyModuleUniforms(ctx, mod, uniforms); err != nil {
		returnErr = err
		return
	}

	var input contentData
	// Get input_ptr and input_cap (required)
	inputPtr, ok, err := getExportedValue(ctx, mod, "input_ptr")
	if err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	}
	if !ok {
		returnErr = errors.New("wasm module must export input_ptr as global or function")
		return
	}

	inputCap, ok, err := getExportedValue(ctx, mod, "input_utf8_cap")
	if err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	}
	if ok {
		input.encoding = dataEncodingUTF8
	} else if cap, ok, err := getExportedValue(ctx, mod, "input_bytes_cap"); err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	} else if ok {
		inputCap = cap
		input.encoding = dataEncodingRaw
	} else {
		returnErr = errors.New("wasm module must export input_utf8_cap or input_bytes_cap as global or function")
		return
	}
	exec.inputCapBytes = inputCap

	var outputPtr, outputCap uint32
	if ptr, ok, err := getExportedValue(ctx, mod, "output_ptr"); err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	} else if ok {
		outputPtr = uint32(ptr)

		if cap, ok, err := getExportedValue(ctx, mod, "output_utf8_cap"); err != nil {
			returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
			return
		} else if ok {
			outputCap = uint32(cap)
			exec.output.encoding = dataEncodingUTF8
		} else if cap, ok, err := getExportedValue(ctx, mod, "output_i32_cap"); err != nil {
			returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
			return
		} else if ok {
			outputCap = uint32(cap)
			exec.output.encoding = dataEncodingArrayI32
		} else if cap, ok, err := getExportedValue(ctx, mod, "output_bytes_cap"); err != nil {
			returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
			return
		} else if ok {
			outputCap = uint32(cap)
			exec.output.encoding = dataEncodingRaw
		} else {
			returnErr = errors.New("wasm module must export output_utf8_cap or output_i32_cap or output_bytes_cap as global or function")
			return
		}
	}
	exec.outputCapBytes = uint64(outputCap)

	declaredInputContentType, hasDeclaredInputContentType, err := readOptionalModuleContentType(ctx, mod, "input")
	if err != nil {
		returnErr = err
		return
	}
	declaredOutputContentType, hasDeclaredOutputContentType, err := readOptionalModuleContentType(ctx, mod, "output")
	if err != nil {
		returnErr = err
		return
	}
	incomingContentType = normalizeIncomingContentType(incomingContentType)
	effectiveIncomingContentType := incomingContentType
	if effectiveIncomingContentType == "" && hasDeclaredInputContentType && allowMissingInputContentType {
		effectiveIncomingContentType = declaredInputContentType
	}

	if opts.contentTypeChecking == ContentTypeCheckingStrong && hasDeclaredInputContentType {
		if effectiveIncomingContentType == "" {
			if !allowMissingInputContentType {
				returnErr = fmt.Errorf("content type check failed for %s: module expects %q but pipeline content type is unspecified", moduleName, declaredInputContentType)
				return
			}
		} else if effectiveIncomingContentType != declaredInputContentType {
			returnErr = fmt.Errorf("content type check failed for %s: module expects %q, got %q", moduleName, declaredInputContentType, effectiveIncomingContentType)
			return
		}
	}

	switch {
	case hasDeclaredOutputContentType:
		exec.outputContentType = declaredOutputContentType
	case exec.output.encoding == dataEncodingUTF8 || exec.output.encoding == dataEncodingRaw:
		exec.outputContentType = effectiveIncomingContentType
	default:
		exec.outputContentType = ""
	}

	runFunc := mod.ExportedFunction("run")
	if runFunc == nil {
		returnErr = errors.New("wasm module must export run(i32) -> i32")
		return
	}

	var inputSize = uint64(len(inputBytes))
	if inputSize > inputCap {
		returnErr = errors.New("input is too large")
		return
	}

	mem := mod.Memory()
	if !mem.Write(uint32(inputPtr), inputBytes) {
		returnErr = errors.New("could not write input")
		return
	}

	runStart := time.Now()
	runResult, returnErr := runFunc.Call(ctx, inputSize)
	exec.run = time.Since(runStart)
	if returnErr != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, returnErr)
		return
	}

	outputCount := uint32(runResult[0])

	var outputItemFactor uint32
	if exec.output.encoding == dataEncodingArrayI32 {
		outputItemFactor = 4
	} else {
		outputItemFactor = 1
	}

	outputCountBytes := outputItemFactor * outputCount

	if outputCap > 0 {
		if outputCount > outputCap {
			returnErr = errors.New("module returned more bytes than its stated capacity")
			return
		}
		outputBytes, ok := mem.Read(outputPtr, uint32(outputCountBytes))
		if !ok {
			returnErr = errors.New("could not read output")
			return
		}
		// Copy out of wasm memory so callers can safely use the bytes after module close.
		exec.output.bytes = append([]byte(nil), outputBytes...)
		if opts.verbose && len(exec.output.bytes) > 0 {
			sum := sha256.Sum256(exec.output.bytes)
			vlogf(opts, "output sha256: %x", sum)
		}
	} else {
		fmt.Printf("Ran: %d\n", runResult[0])
	}

	exec.memoryBytes = memorySizeBytes(mem)
	return
}

func memorySizeBytes(mem api.Memory) uint64 {
	size := mem.Size()
	if size != 0 {
		return uint64(size)
	}
	// Work around wazero's uint32 overflow behavior on max memory.
	pages, ok := mem.Grow(0)
	if !ok {
		return 0
	}
	return uint64(pages) * 65536
}

func gameOver(format string, args ...any) {
	log.SetFlags(0)
	log.Fatalf(format, args...)
}

func vlogf(opts options, format string, args ...any) {
	if !opts.verbose {
		return
	}
	log.SetFlags(0)
	log.Printf(format, args...)
}

type recipeCandidate struct {
	path     string
	filename string
	order    int
	digest   [32]byte
}

type moduleFileStamp struct {
	modTimeUnixNano int64
	sizeBytes       int64
}

type moduleAsset struct {
	body        []byte
	contentType string
}

type devRuntimeState struct {
	contentRoutes      map[string]qinternal.ContentRoute
	routeOptions       qinternal.RouteOptions
	recipeChains       map[string]*qinternal.Pipeline
	recipeOutput       map[string]string
	recipeDigests      map[string][][32]byte
	recipeStamps       map[string]moduleFileStamp
	recipeSourceAssets []qinternal.RecipeSourceAsset
	recipeSourceByPath map[string]qinternal.RecipeSourceAsset
	recipeSourceIndex  []byte
	formModules        map[string][]byte
	formDigests        map[string][32]byte
	moduleAssets       map[string]moduleAsset
	moduleRequestPaths []string
}

func devCmd(args []string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var formsRoot string
	var modulesRoot string
	var modeRaw string
	port := 4000
	fs := flag.NewFlagSet("dev", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var devVerbose bool
	fs.BoolVar(&devVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&devVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe modules root directory")
	fs.StringVar(&formsRoot, "forms", "", "form modules root directory")
	fs.StringVar(&modulesRoot, "modules", "", "browser-loadable wasm modules root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	fs.BoolVar(&opts.viewSource, "view-source", false, "serve /view-source plus recipe source files from --recipes")
	fs.IntVar(&port, "p", 4000, "port")
	if err := fs.Parse(normalizeDevArgs(args)); err != nil {
		gameOver("%s %v", usageDev, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = devVerbose
	opts.mode = mode
	contentArgs := fs.Args()
	if len(contentArgs) != 1 {
		gameOver(usageDev)
	}
	contentRoot := contentArgs[0]
	if port <= 0 || port > 65535 {
		gameOver("Invalid port: %d", port)
	}

	contentInfo, err := os.Stat(contentRoot)
	if err != nil {
		gameOver("Invalid content directory: %v", err)
	}
	if !contentInfo.IsDir() {
		gameOver("Invalid content directory: %q is not a directory", contentRoot)
	}

	if recipesRoot != "" {
		recipeInfo, err := os.Stat(recipesRoot)
		if err != nil {
			gameOver("Invalid recipes directory: %v", err)
		}
		if !recipeInfo.IsDir() {
			gameOver("Invalid recipes directory: %q is not a directory", recipesRoot)
		}
	}
	if opts.viewSource && recipesRoot == "" {
		gameOver("--view-source requires --recipes <recipes_dir>")
	}

	if formsRoot != "" {
		formInfo, err := os.Stat(formsRoot)
		if err != nil {
			gameOver("Invalid forms directory: %v", err)
		}
		if !formInfo.IsDir() {
			gameOver("Invalid forms directory: %q is not a directory", formsRoot)
		}
	}
	if modulesRoot != "" {
		moduleInfo, err := os.Stat(modulesRoot)
		if err != nil {
			gameOver("Invalid modules directory: %v", err)
		}
		if !moduleInfo.IsDir() {
			gameOver("Invalid modules directory: %q is not a directory", modulesRoot)
		}
	}

	routeOptions := qinternal.DefaultRouteOptions()
	state, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, modulesRoot, opts, routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	var stateMu sync.RWMutex
	var reloadMu sync.Mutex
	swapRuntimeState := func(nextState *devRuntimeState) {
		stateMu.Lock()
		previous := state
		state = nextState
		stateMu.Unlock()
		if previous != nil {
			closePipelines(context.Background(), previous.recipeChains)
		}
	}
	reloadRuntimeState := func(reason string) {
		reloadMu.Lock()
		defer reloadMu.Unlock()

		reloadStart := time.Now()
		nextState, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, modulesRoot, opts, routeOptions)
		if err != nil {
			log.Printf("dev: reload failed reason=%s error=%v", reason, err)
			return
		}

		swapRuntimeState(nextState)
		log.Printf("dev: reloaded reason=%s paths=%d recipe_mimes=%d forms=%d modules=%d duration_ms=%d", reason, len(nextState.contentRoutes), len(nextState.recipeChains), len(nextState.formModules), len(nextState.moduleAssets), time.Since(reloadStart).Milliseconds())
	}
	reloadRecipesIfChanged := func() {
		if opts.mode != modeDev || recipesRoot == "" {
			return
		}

		reloadMu.Lock()
		defer reloadMu.Unlock()

		stamps, err := scanRecipeModuleStamps(recipesRoot)
		if err != nil {
			log.Printf("dev: recipe change check failed: %v", err)
			return
		}

		stateMu.RLock()
		currentStamps := state.recipeStamps
		unchanged := recipeModuleStampsEqual(currentStamps, stamps)
		stateMu.RUnlock()
		if unchanged {
			return
		}

		reloadStart := time.Now()
		nextState, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, modulesRoot, opts, routeOptions)
		if err != nil {
			log.Printf("dev: auto-reload failed reason=recipe_change error=%v", err)
			return
		}

		swapRuntimeState(nextState)
		log.Printf("dev: reloaded reason=recipe_change paths=%d recipe_mimes=%d forms=%d modules=%d duration_ms=%d", len(nextState.contentRoutes), len(nextState.recipeChains), len(nextState.formModules), len(nextState.moduleAssets), time.Since(reloadStart).Milliseconds())
	}

	defer func() {
		stateMu.Lock()
		current := state
		state = nil
		stateMu.Unlock()
		if current != nil {
			closePipelines(context.Background(), current.recipeChains)
		}
	}()

	log.Printf("dev: indexed %d request paths from %s", len(state.contentRoutes), contentRoot)
	if recipesRoot != "" {
		log.Printf("dev: loaded %d recipe mime chains from %s", len(state.recipeChains), recipesRoot)
	}
	if formsRoot != "" {
		log.Printf("dev: loaded %d form modules from %s", len(state.formModules), formsRoot)
	}
	if modulesRoot != "" {
		log.Printf("dev: loaded %d browser modules from %s", len(state.moduleAssets), modulesRoot)
	}

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	handlerTimeouts := routeHandlerTimeouts{
		contentRecipe:   defaultRouteContentRecipeTimeout,
		applicationWARC: defaultRouteApplicationWARCTimeout,
	}
	handler := newDevRequestHandler("dev", &stateMu, &state, reloadRecipesIfChanged, routeOptions, handlerTimeouts)

	server := &http.Server{
		Addr:    addr,
		Handler: handler,
	}

	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	hupCh := make(chan os.Signal, 1)
	signal.Notify(hupCh, syscall.SIGHUP)
	defer signal.Stop(hupCh)

	var reloadWG sync.WaitGroup
	reloadWG.Go(func() {
		for {
			select {
			case <-signalCtx.Done():
				return
			case <-hupCh:
				reloadRuntimeState("signal_hup")
			}
		}
	})
	defer func() {
		stop()
		reloadWG.Wait()
	}()

	go func() {
		<-signalCtx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("dev: listening on http://%s", addr)
	log.Printf("dev: send SIGHUP to reload routes, recipes, forms, and modules: `kill -HUP %d`", os.Getpid())

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		gameOver("dev server error: %v", err)
	}
}

func routePathCmd(args []string, method string, usage string, logPrefix string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var formsRoot string
	var modulesRoot string
	var modeRaw string

	fs := flag.NewFlagSet("route "+strings.ToLower(method), flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var routeVerbose bool
	fs.BoolVar(&routeVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&routeVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe modules root directory")
	fs.StringVar(&formsRoot, "forms", "", "form modules root directory")
	fs.StringVar(&modulesRoot, "modules", "", "browser-loadable wasm modules root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	if err := fs.Parse(normalizeRouteArgs(args)); err != nil {
		gameOver("%s %v", usage, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = routeVerbose
	opts.mode = mode

	rest := fs.Args()
	if len(rest) != 2 {
		gameOver("%s", usage)
	}
	contentRoot := rest[0]
	requestPath := rest[1]
	if requestPath == "" {
		requestPath = "/"
	}

	contentInfo, err := os.Stat(contentRoot)
	if err != nil {
		gameOver("Invalid content directory: %v", err)
	}
	if !contentInfo.IsDir() {
		gameOver("Invalid content directory: %q is not a directory", contentRoot)
	}

	if recipesRoot != "" {
		recipeInfo, err := os.Stat(recipesRoot)
		if err != nil {
			gameOver("Invalid recipes directory: %v", err)
		}
		if !recipeInfo.IsDir() {
			gameOver("Invalid recipes directory: %q is not a directory", recipesRoot)
		}
	}

	if formsRoot != "" {
		formInfo, err := os.Stat(formsRoot)
		if err != nil {
			gameOver("Invalid forms directory: %v", err)
		}
		if !formInfo.IsDir() {
			gameOver("Invalid forms directory: %q is not a directory", formsRoot)
		}
	}
	if modulesRoot != "" {
		moduleInfo, err := os.Stat(modulesRoot)
		if err != nil {
			gameOver("Invalid modules directory: %v", err)
		}
		if !moduleInfo.IsDir() {
			gameOver("Invalid modules directory: %q is not a directory", modulesRoot)
		}
	}

	routeOptions := qinternal.DefaultRouteOptions()
	state, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, modulesRoot, opts, routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	var stateMu sync.RWMutex
	defer func() {
		stateMu.Lock()
		current := state
		state = nil
		stateMu.Unlock()
		if current != nil {
			closePipelines(context.Background(), current.recipeChains)
		}
	}()

	handlerTimeouts := routeHandlerTimeouts{
		contentRecipe:   defaultRouteContentRecipeTimeout,
		applicationWARC: defaultRouteApplicationWARCTimeout,
	}
	handler := newDevRequestHandler(logPrefix, &stateMu, &state, nil, routeOptions, handlerTimeouts)
	response, err := qinternal.ServeInProcessHTTP(handler, method, requestPath, nil)
	if err != nil {
		gameOver("%v", err)
	}

	if contentType := response.Header.Get("Content-Type"); contentType != "" {
		log.Printf("%s: Content-Type: %s", logPrefix, contentType)
	}
	if etag := response.Header.Get("ETag"); etag != "" {
		log.Printf("%s: ETag: %s", logPrefix, etag)
	}
	if location := response.Header.Get("Location"); location != "" {
		log.Printf("%s: Location: %s", logPrefix, location)
	}
	contentLength := response.Header.Get("Content-Length")
	if contentLength == "" {
		contentLength = strconv.Itoa(len(response.Body))
	}
	log.Printf("%s: Content-Length: %s", logPrefix, contentLength)

	if method != http.MethodHead && len(response.Body) > 0 {
		if _, err := os.Stdout.Write(response.Body); err != nil {
			gameOver("Error writing response body: %v", err)
		}
	}

	if response.StatusCode >= http.StatusBadRequest {
		statusText := http.StatusText(response.StatusCode)
		if statusText == "" {
			gameOver("%d", response.StatusCode)
		}
		gameOver("%d %s", response.StatusCode, statusText)
	}
}

type routeListEntry struct {
	Method      string
	Path        string
	ContentType string
}

func routeListCmd(args []string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var formsRoot string
	var modulesRoot string
	var modeRaw string

	fs := flag.NewFlagSet("route list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var routeVerbose bool
	fs.BoolVar(&routeVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&routeVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe modules root directory")
	fs.StringVar(&formsRoot, "forms", "", "form modules root directory")
	fs.StringVar(&modulesRoot, "modules", "", "browser-loadable wasm modules root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	if err := fs.Parse(normalizeRouteArgs(args)); err != nil {
		gameOver("%s %v", usageRouteList, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = routeVerbose
	opts.mode = mode

	rest := fs.Args()
	if len(rest) != 1 {
		gameOver("%s", usageRouteList)
	}
	contentRoot := rest[0]

	contentInfo, err := os.Stat(contentRoot)
	if err != nil {
		gameOver("Invalid content directory: %v", err)
	}
	if !contentInfo.IsDir() {
		gameOver("Invalid content directory: %q is not a directory", contentRoot)
	}

	if recipesRoot != "" {
		recipeInfo, err := os.Stat(recipesRoot)
		if err != nil {
			gameOver("Invalid recipes directory: %v", err)
		}
		if !recipeInfo.IsDir() {
			gameOver("Invalid recipes directory: %q is not a directory", recipesRoot)
		}
	}

	if formsRoot != "" {
		formInfo, err := os.Stat(formsRoot)
		if err != nil {
			gameOver("Invalid forms directory: %v", err)
		}
		if !formInfo.IsDir() {
			gameOver("Invalid forms directory: %q is not a directory", formsRoot)
		}
	}
	if modulesRoot != "" {
		moduleInfo, err := os.Stat(modulesRoot)
		if err != nil {
			gameOver("Invalid modules directory: %v", err)
		}
		if !moduleInfo.IsDir() {
			gameOver("Invalid modules directory: %q is not a directory", modulesRoot)
		}
	}

	routeOptions := qinternal.DefaultRouteOptions()
	state, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, modulesRoot, opts, routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	defer closePipelines(context.Background(), state.recipeChains)

	entries := buildRouteListEntries(state)
	for _, entry := range entries {
		fmt.Printf("%-4s %s  %s\n", entry.Method, entry.Path, entry.ContentType)
	}
}

func buildRouteListEntries(state *devRuntimeState) []routeListEntry {
	if state == nil {
		return nil
	}

	canonicalRoutes := make(map[string]qinternal.ContentRoute, len(state.contentRoutes))
	for requestPath := range state.contentRoutes {
		canonicalPath, _ := qinternal.CanonicalRequestPath(requestPath, state.routeOptions)
		if _, exists := canonicalRoutes[canonicalPath]; exists {
			continue
		}
		route, ok := qinternal.ResolveContentRoute(state.contentRoutes, canonicalPath, state.routeOptions)
		if !ok {
			continue
		}
		canonicalRoutes[canonicalPath] = route
	}

	paths := make([]string, 0, len(canonicalRoutes))
	for requestPath := range canonicalRoutes {
		paths = append(paths, requestPath)
	}
	sort.Strings(paths)

	entries := make([]routeListEntry, 0, len(paths)*2)
	for _, requestPath := range paths {
		route := canonicalRoutes[requestPath]
		hasRecipes := shouldApplyRecipesForRequestPath(requestPath, route, state.recipeChains)
		contentType := devResponseContentType(route.SourceMIME, hasRecipes, qinternal.NewRawBytesContent(nil), nil)
		if hasRecipes {
			if recipeType := state.recipeOutput[route.SourceMIME]; recipeType != "" {
				contentType = recipeType
			}
		}
		contentType = mediaTypeOnly(contentType)
		entries = append(entries, routeListEntry{
			Method:      http.MethodGet,
			Path:        requestPath,
			ContentType: contentType,
		})
		entries = append(entries, routeListEntry{
			Method:      http.MethodHead,
			Path:        requestPath,
			ContentType: contentType,
		})
	}
	for _, requestPath := range state.moduleRequestPaths {
		asset, ok := state.moduleAssets[requestPath]
		if !ok {
			continue
		}
		contentType := mediaTypeOnly(asset.contentType)
		entries = append(entries, routeListEntry{
			Method:      http.MethodGet,
			Path:        requestPath,
			ContentType: contentType,
		})
		entries = append(entries, routeListEntry{
			Method:      http.MethodHead,
			Path:        requestPath,
			ContentType: contentType,
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Path != entries[j].Path {
			return entries[i].Path < entries[j].Path
		}
		return entries[i].Method < entries[j].Method
	})
	return entries
}

func mediaTypeOnly(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "application/octet-stream"
	}
	mediaType, _, err := mime.ParseMediaType(value)
	if err == nil && mediaType != "" {
		return mediaType
	}
	if cut := strings.IndexByte(value, ';'); cut != -1 {
		value = strings.TrimSpace(value[:cut])
	}
	if value == "" {
		return "application/octet-stream"
	}
	return value
}

func routeCmd(args []string) {
	if len(args) == 0 {
		gameOver(usageRoute)
	}
	switch args[0] {
	case "get":
		routePathCmd(args[1:], http.MethodGet, usageRouteGet, "route get")
		return
	case "head":
		routePathCmd(args[1:], http.MethodHead, usageRouteHead, "route head")
		return
	case "list":
		routeListCmd(args[1:])
		return
	case "warc":
	default:
		gameOver(usageRoute)
	}

	type routeRuntime struct {
		state        *devRuntimeState
		handler      http.Handler
		routeOptions qinternal.RouteOptions
	}
	handlerTimeouts := routeHandlerTimeouts{
		contentRecipe:   defaultRouteContentRecipeTimeout,
		applicationWARC: defaultRouteApplicationWARCTimeout,
	}
	warcTransformTimeout := defaultRouteWARCTransformTimeout
	var runtimeMu sync.Mutex
	var runtime *routeRuntime
	ensureRuntime := func(ctx context.Context, request qcmd.RouteWARCRequest) (*routeRuntime, error) {
		runtimeMu.Lock()
		defer runtimeMu.Unlock()
		if runtime != nil {
			return runtime, nil
		}

		mode, err := parseRuntimeMode(request.ModeRaw)
		if err != nil {
			return nil, err
		}
		opts := options{
			verbose:             request.Verbose,
			mode:                mode,
			contentTypeChecking: ContentTypeCheckingStrong,
		}

		contentInfo, err := os.Stat(request.ContentRoot)
		if err != nil {
			return nil, fmt.Errorf("invalid content directory: %v", err)
		}
		if !contentInfo.IsDir() {
			return nil, fmt.Errorf("invalid content directory: %q is not a directory", request.ContentRoot)
		}

		if request.RecipesRoot != "" {
			recipeInfo, err := os.Stat(request.RecipesRoot)
			if err != nil {
				return nil, fmt.Errorf("invalid recipes directory: %v", err)
			}
			if !recipeInfo.IsDir() {
				return nil, fmt.Errorf("invalid recipes directory: %q is not a directory", request.RecipesRoot)
			}
		}

		if request.FormsRoot != "" {
			formInfo, err := os.Stat(request.FormsRoot)
			if err != nil {
				return nil, fmt.Errorf("invalid forms directory: %v", err)
			}
			if !formInfo.IsDir() {
				return nil, fmt.Errorf("invalid forms directory: %q is not a directory", request.FormsRoot)
			}
		}
		if request.ModulesRoot != "" {
			moduleInfo, err := os.Stat(request.ModulesRoot)
			if err != nil {
				return nil, fmt.Errorf("invalid modules directory: %v", err)
			}
			if !moduleInfo.IsDir() {
				return nil, fmt.Errorf("invalid modules directory: %q is not a directory", request.ModulesRoot)
			}
		}

		routeOptions := qinternal.DefaultRouteOptions()
		state, err := loadDevRuntimeState(ctx, request.ContentRoot, request.RecipesRoot, request.FormsRoot, request.ModulesRoot, opts, routeOptions)
		if err != nil {
			return nil, err
		}
		var stateMu sync.RWMutex
		handler := newDevRequestHandler("route", &stateMu, &state, nil, routeOptions, handlerTimeouts)
		runtime = &routeRuntime{
			state:        state,
			handler:      handler,
			routeOptions: routeOptions,
		}
		return runtime, nil
	}
	defer func() {
		runtimeMu.Lock()
		defer runtimeMu.Unlock()
		if runtime == nil || runtime.state == nil {
			return
		}
		closePipelines(context.Background(), runtime.state.recipeChains)
		runtime.state = nil
	}()

	if err := qcmd.RunRoute(args, qcmd.RouteConfig{
		UsageRoute:     usageRoute,
		UsageRouteWarc: usageRouteWarc,
		DefaultMode:    string(modeDev),
		ListWARCPaths: func(ctx context.Context, request qcmd.RouteWARCRequest) ([]string, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return nil, err
			}

			pathSet := make(map[string]struct{}, len(loaded.state.contentRoutes))
			for requestPath := range loaded.state.contentRoutes {
				canonical, _ := qinternal.CanonicalRequestPath(requestPath, loaded.routeOptions)
				pathSet[canonical] = struct{}{}
			}
			for _, requestPath := range loaded.state.moduleRequestPaths {
				pathSet[requestPath] = struct{}{}
			}

			paths := make([]string, 0, len(pathSet))
			for requestPath := range pathSet {
				paths = append(paths, requestPath)
			}
			sort.Strings(paths)
			return paths, nil
		},
		ResolveWARC: func(ctx context.Context, request qcmd.RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return qinternal.InProcessHTTPResponse{}, err
			}
			return qinternal.ServeInProcessHTTP(loaded.handler, http.MethodGet, request.RequestPath, nil)
		},
		TransformWARC: func(ctx context.Context, request qcmd.RouteWARCRequest, warc []byte) ([]byte, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return nil, err
			}
			pipeline := loaded.state.recipeChains[applicationWARCRecipeMIME]
			if pipeline == nil {
				return warc, nil
			}
			execCtx, cancel := withExecutionTimeout(ctx, warcTransformTimeout)
			defer cancel()
			transformed, err := processApplicationWARCArchive(execCtx, pipeline, warc, 0)
			if err != nil {
				return nil, err
			}
			return transformed, nil
		},
		Verbosef: func(format string, args ...any) {
			log.Printf(format, args...)
		},
	}); err != nil {
		gameOver("%v", err)
	}
}

func newDevRequestHandler(logPrefix string, stateMu *sync.RWMutex, state **devRuntimeState, reloadRecipesIfChanged func(), routeOptions qinternal.RouteOptions, timeouts routeHandlerTimeouts) http.Handler {
	return qinternal.NewRequestHandler(qinternal.RequestHandlerConfig{
		LogPrefix:    logPrefix,
		RouteOptions: routeOptions,
		Reload:       reloadRecipesIfChanged,
		WriteError: func(w http.ResponseWriter, err error) {
			writeDevError(w, err)
		},
		FormatDuration: formatDurationParts,
		Logf: func(format string, args ...any) {
			log.Printf(format, args...)
		},
		Resolve: func(r *http.Request, reqID uint64) (qinternal.RoutedResponse, error) {
			stateMu.RLock()
			current := *state
			if current == nil {
				stateMu.RUnlock()
				return qinternal.RoutedResponse{}, errors.New("runtime state is unavailable")
			}
			if response, ok := resolveRecipeSourceResponse(r.URL.Path, current); ok {
				stateMu.RUnlock()
				return response, nil
			}
			if response, ok := resolveModuleAssetResponse(r.URL.Path, current); ok {
				stateMu.RUnlock()
				return response, nil
			}

			route, ok := qinternal.ResolveContentRoute(current.contentRoutes, r.URL.Path, current.routeOptions)
			if !ok {
				stateMu.RUnlock()
				return qinternal.RoutedResponse{
					StatusCode: http.StatusNotFound,
					Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
					Body:       []byte("404 page not found\n"),
				}, nil
			}

			inputBytes, err := os.ReadFile(route.FilePath)
			if err != nil {
				stateMu.RUnlock()
				return qinternal.RoutedResponse{}, err
			}
			sourceDigest := sha256.Sum256(inputBytes)

			var result qinternal.Content = qinternal.NewRawBytesContentWithType(inputBytes, route.SourceMIME)
			hasRecipes := shouldApplyRecipesForRequestPath(r.URL.Path, route, current.recipeChains)
			if hasRecipes {
				pipeline := current.recipeChains[route.SourceMIME]
				ctx := context.Background()
				ctx, cancel := withExecutionTimeout(ctx, timeouts.contentRecipe)
				defer cancel()
				result, err = pipeline.Process(ctx, result, reqID)
				if err != nil {
					stateMu.RUnlock()
					return qinternal.RoutedResponse{}, err
				}
			}

			result, body, err := ensureRawContent(result)
			if err != nil {
				stateMu.RUnlock()
				return qinternal.RoutedResponse{}, err
			}

			contentType := devResponseContentType(route.SourceMIME, hasRecipes, result, body)
			formDigests := make([][32]byte, 0)
			if strings.HasPrefix(contentType, "text/html") {
				body, formDigests, err = injectQIPFormRuntime(body, current.formModules, current.formDigests)
				if err != nil {
					stateMu.RUnlock()
					return qinternal.RoutedResponse{
						ModuleDurations:        []time.Duration{},
						InstantiationDurations: []time.Duration{},
					}, err
				}
				body = injectQIPPreviewRuntime(body)
			}

			response := qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{contentType}},
				Body:       body,
			}
			applicationWARCPipeline := current.recipeChains[applicationWARCRecipeMIME]
			if applicationWARCPipeline != nil {
				ctx := context.Background()
				ctx, cancel := withExecutionTimeout(ctx, timeouts.applicationWARC)
				defer cancel()
				response, err = transformRouteResponseWithApplicationWARC(ctx, applicationWARCPipeline, r.URL.Path, response, reqID)
				if err != nil {
					stateMu.RUnlock()
					return qinternal.RoutedResponse{}, err
				}
			}

			headers := response.Header.Clone()
			if headers == nil {
				headers = make(http.Header)
			}
			if headers.Get("Content-Type") == "" {
				headers.Set("Content-Type", contentType)
			}
			headers.Del("Content-Length")
			recipeDigests := make([][32]byte, 0)
			if hasRecipes {
				recipeDigests = append(recipeDigests, current.recipeDigests[route.SourceMIME]...)
			}
			if applicationRecipeDigests := current.recipeDigests[applicationWARCRecipeMIME]; len(applicationRecipeDigests) > 0 {
				recipeDigests = append(recipeDigests, applicationRecipeDigests...)
			}
			etag := buildDevETag(sourceDigest, recipeDigests, formDigests)
			if etag != "" {
				headers.Set("ETag", etag)
				if r.Header.Get("If-None-Match") == etag {
					stateMu.RUnlock()
					return qinternal.RoutedResponse{
						StatusCode:             http.StatusNotModified,
						Header:                 headers,
						ModuleDurations:        []time.Duration{},
						InstantiationDurations: []time.Duration{},
					}, nil
				}
			}
			stateMu.RUnlock()

			statusCode := response.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusOK
			}
			return qinternal.RoutedResponse{
				StatusCode:             statusCode,
				Header:                 headers,
				Body:                   response.Body,
				ModuleDurations:        []time.Duration{},
				InstantiationDurations: []time.Duration{},
			}, nil
		},
	})
}

func resolveRecipeSourceResponse(requestPath string, state *devRuntimeState) (qinternal.RoutedResponse, bool) {
	if state == nil || len(state.recipeSourceIndex) == 0 {
		return qinternal.RoutedResponse{}, false
	}
	switch requestPath {
	case "/view-source", "/view-source/":
		return qinternal.RoutedResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
			Body:       state.recipeSourceIndex,
		}, true
	}
	asset, ok := state.recipeSourceByPath[requestPath]
	if !ok {
		return qinternal.RoutedResponse{}, false
	}
	return qinternal.RoutedResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{asset.ContentType}},
		Body:       asset.Body,
	}, true
}

func resolveModuleAssetResponse(requestPath string, state *devRuntimeState) (qinternal.RoutedResponse, bool) {
	if state == nil || len(state.moduleAssets) == 0 {
		return qinternal.RoutedResponse{}, false
	}
	asset, ok := state.moduleAssets[requestPath]
	if !ok {
		return qinternal.RoutedResponse{}, false
	}
	return qinternal.RoutedResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{asset.contentType}},
		Body:       asset.body,
	}, true
}

func loadDevRuntimeState(ctx context.Context, contentRoot string, recipesRoot string, formsRoot string, modulesRoot string, opts options, routeOptions qinternal.RouteOptions) (*devRuntimeState, error) {
	contentRoutes, err := qinternal.BuildContentRoutes(contentRoot, routeOptions)
	if err != nil {
		return nil, err
	}
	recipeChains, recipeDigests, err := loadRecipeChains(ctx, recipesRoot, opts)
	if err != nil {
		return nil, err
	}
	recipeOutput := inferRecipeOutputContentTypes(ctx, recipeChains)
	recipeStamps, err := scanRecipeModuleStamps(recipesRoot)
	if err != nil {
		closePipelines(ctx, recipeChains)
		return nil, err
	}
	formModules, formDigests, err := loadFormModules(formsRoot)
	if err != nil {
		closePipelines(ctx, recipeChains)
		return nil, err
	}
	moduleAssets, moduleRequestPaths, err := loadModuleAssets(modulesRoot)
	if err != nil {
		closePipelines(ctx, recipeChains)
		return nil, err
	}
	recipeSourceAssets := make([]qinternal.RecipeSourceAsset, 0)
	var moduleSourceAssets []qinternal.RecipeSourceAsset
	recipeSourceByPath := make(map[string]qinternal.RecipeSourceAsset)
	recipeSourceIndex := []byte(nil)
	if opts.viewSource && recipesRoot != "" {
		recipeSourceAssets, err = qinternal.CollectRecipeSourceAssets(recipesRoot)
		if err != nil {
			closePipelines(ctx, recipeChains)
			return nil, err
		}
		moduleSourceAssets, err = qinternal.CollectModuleSourceAssets(modulesRoot)
		if err != nil {
			closePipelines(ctx, recipeChains)
			return nil, err
		}
		markdownPaths := qinternal.CollectMarkdownRequestPathsFromRoutes(contentRoutes)
		recipeSourceIndex = qinternal.BuildViewSourceIndexHTML(recipeSourceAssets, markdownPaths, moduleRequestPaths, moduleSourceAssets)
		recipeSourceByPath = make(map[string]qinternal.RecipeSourceAsset, len(recipeSourceAssets)+len(moduleSourceAssets))
		for _, asset := range recipeSourceAssets {
			recipeSourceByPath[asset.RequestPath] = asset
		}
		for _, asset := range moduleSourceAssets {
			recipeSourceByPath[asset.RequestPath] = asset
		}
	}
	return &devRuntimeState{
		contentRoutes:      contentRoutes,
		routeOptions:       routeOptions,
		recipeChains:       recipeChains,
		recipeOutput:       recipeOutput,
		recipeDigests:      recipeDigests,
		recipeStamps:       recipeStamps,
		recipeSourceAssets: recipeSourceAssets,
		recipeSourceByPath: recipeSourceByPath,
		recipeSourceIndex:  recipeSourceIndex,
		formModules:        formModules,
		formDigests:        formDigests,
		moduleAssets:       moduleAssets,
		moduleRequestPaths: moduleRequestPaths,
	}, nil
}

func normalizeRunArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"-i":           {},
		"-o":           {},
		"--output":     {},
		"--timeout-ms": {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func normalizeBenchArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"-i":           {},
		"-r":           {},
		"--benchtime":  {},
		"--timeout-ms": {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func normalizeImageArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"-i":           {},
		"-o":           {},
		"--timeout-ms": {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func normalizeDevArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"--recipes": {},
		"--forms":   {},
		"--modules": {},
		"--mode":    {},
		"-p":        {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func normalizeRouteArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"--recipes": {},
		"--forms":   {},
		"--modules": {},
		"--mode":    {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func parseRuntimeMode(raw string) (runtimeMode, error) {
	mode := runtimeMode(strings.ToLower(strings.TrimSpace(raw)))
	switch mode {
	case modeDev, modeProd:
		return mode, nil
	default:
		return "", fmt.Errorf("invalid mode %q (expected dev or prod)", raw)
	}
}

func parseRecipeFilename(filename string) (order int, disabled bool, err error) {
	if !isASCII(filename) {
		return 0, false, errors.New("filename must be ASCII")
	}
	if !strings.HasSuffix(filename, ".wasm") {
		return 0, false, errors.New("filename must end with .wasm")
	}

	trimmed := filename
	if strings.HasPrefix(trimmed, "-") {
		disabled = true
		trimmed = trimmed[1:]
	}

	if len(trimmed) < len("00-a.wasm") {
		return 0, disabled, errors.New("filename must match NN-name.wasm")
	}
	if trimmed[0] < '0' || trimmed[0] > '9' || trimmed[1] < '0' || trimmed[1] > '9' {
		return 0, disabled, errors.New("filename prefix must be two digits")
	}
	if trimmed[2] != '-' {
		return 0, disabled, errors.New("filename must match NN-name.wasm")
	}
	namePart := strings.TrimSuffix(trimmed, ".wasm")[3:]
	if namePart == "" {
		return 0, disabled, errors.New("recipe name must not be empty")
	}

	order = int(trimmed[0]-'0')*10 + int(trimmed[1]-'0')
	return order, disabled, nil
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] > 0x7f {
			return false
		}
	}
	return true
}

func walkFilesFollowingSymlinks(root string, entryKind string, visit func(fullPath string, info fs.FileInfo) error) error {
	seenDirs := make(map[string]uint8)
	var walkDir func(readDir string) error
	walkDir = func(readDir string) error {
		realDir, err := filepath.EvalSymlinks(readDir)
		if err != nil {
			return err
		}
		realDir, err = filepath.Abs(realDir)
		if err != nil {
			return err
		}
		realDir = filepath.Clean(realDir)
		if seenDirs[realDir] > 0 {
			// Avoid infinite recursion when a symlink points back to an ancestor.
			return nil
		}
		seenDirs[realDir]++
		defer func() {
			seenDirs[realDir]--
		}()

		entries, err := os.ReadDir(readDir)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			fullPath := filepath.Join(readDir, entry.Name())
			mode := entry.Type()
			if mode.IsRegular() {
				info, err := entry.Info()
				if err != nil {
					return err
				}
				if err := visit(fullPath, info); err != nil {
					return err
				}
				continue
			}
			if mode.IsDir() {
				if err := walkDir(fullPath); err != nil {
					return err
				}
				continue
			}
			if mode&fs.ModeSymlink == 0 {
				return fmt.Errorf("%s entry %q must be a regular file", entryKind, fullPath)
			}

			targetInfo, err := os.Stat(fullPath)
			if err != nil {
				return err
			}
			if targetInfo.Mode().IsRegular() {
				if err := visit(fullPath, targetInfo); err != nil {
					return err
				}
				continue
			}
			if targetInfo.IsDir() {
				if err := walkDir(fullPath); err != nil {
					return err
				}
				continue
			}
			return fmt.Errorf("%s entry %q must be a regular file", entryKind, fullPath)
		}
		return nil
	}

	return walkDir(root)
}

func loadRecipeChains(ctx context.Context, recipesRoot string, opts options) (map[string]*qinternal.Pipeline, map[string][][32]byte, error) {
	chains := make(map[string]*qinternal.Pipeline)
	digestsByMIME := make(map[string][][32]byte)
	if recipesRoot == "" {
		return chains, digestsByMIME, nil
	}

	candidatesByMIME := make(map[string][]recipeCandidate)
	err := walkFilesFollowingSymlinks(recipesRoot, "recipe", func(fullPath string, _ fs.FileInfo) error {
		relPath, err := filepath.Rel(recipesRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		filename := path.Base(relPath)
		if !strings.HasSuffix(filename, ".wasm") {
			return nil
		}
		parts := strings.Split(relPath, "/")
		if len(parts) != 3 {
			return fmt.Errorf("recipe path %q must match <type>/<subtype>/<file>", relPath)
		}
		mimeType := parts[0] + "/" + parts[1]
		filename = parts[2]

		order, disabled, err := parseRecipeFilename(filename)
		if err != nil {
			return fmt.Errorf("invalid recipe filename %q: %w", relPath, err)
		}
		if disabled {
			return nil
		}

		body, err := os.ReadFile(fullPath)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(body)
		candidatesByMIME[mimeType] = append(candidatesByMIME[mimeType], recipeCandidate{
			path:     fullPath,
			filename: filename,
			order:    order,
			digest:   digest,
		})
		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	mimeTypes := make([]string, 0, len(candidatesByMIME))
	for mimeType := range candidatesByMIME {
		mimeTypes = append(mimeTypes, mimeType)
	}
	sort.Strings(mimeTypes)

	for _, mimeType := range mimeTypes {
		candidates := candidatesByMIME[mimeType]
		sort.Slice(candidates, func(i, j int) bool {
			if candidates[i].order != candidates[j].order {
				return candidates[i].order < candidates[j].order
			}
			return candidates[i].filename < candidates[j].filename
		})
		seenOrder := make(map[int]string, len(candidates))
		for _, candidate := range candidates {
			if prevPath, exists := seenOrder[candidate.order]; exists {
				return nil, nil, fmt.Errorf("duplicate recipe prefix for %s: %02d in %q and %q", mimeType, candidate.order, prevPath, candidate.path)
			}
			seenOrder[candidate.order] = candidate.path
		}
		modulePaths := make([]string, len(candidates))
		digests := make([][32]byte, len(candidates))
		for i, candidate := range candidates {
			modulePaths[i] = candidate.path
			digests[i] = candidate.digest
		}
		pipeline, err := buildPipeline(ctx, modulePaths, opts)
		if err != nil {
			closePipelines(ctx, chains)
			return nil, nil, err
		}
		chains[mimeType] = pipeline
		digestsByMIME[mimeType] = digests
	}

	return chains, digestsByMIME, nil
}

func scanRecipeModuleStamps(recipesRoot string) (map[string]moduleFileStamp, error) {
	stamps := make(map[string]moduleFileStamp)
	if recipesRoot == "" {
		return stamps, nil
	}

	err := walkFilesFollowingSymlinks(recipesRoot, "recipe", func(fullPath string, info fs.FileInfo) error {
		if strings.ToLower(path.Ext(fullPath)) != ".wasm" {
			return nil
		}

		relPath, err := filepath.Rel(recipesRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		stamps[relPath] = moduleFileStamp{
			modTimeUnixNano: info.ModTime().UnixNano(),
			sizeBytes:       info.Size(),
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return stamps, nil
}

func recipeModuleStampsEqual(a map[string]moduleFileStamp, b map[string]moduleFileStamp) bool {
	if len(a) != len(b) {
		return false
	}
	for path, stampA := range a {
		stampB, ok := b[path]
		if !ok {
			return false
		}
		if stampA != stampB {
			return false
		}
	}
	return true
}

func loadModuleAssets(modulesRoot string) (map[string]moduleAsset, []string, error) {
	assets := make(map[string]moduleAsset)
	if modulesRoot == "" {
		return assets, nil, nil
	}

	err := walkFilesFollowingSymlinks(modulesRoot, "module", func(fullPath string, _ fs.FileInfo) error {
		relPath, err := filepath.Rel(modulesRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if !utf8.ValidString(relPath) {
			return fmt.Errorf("module path %q must be valid UTF-8", relPath)
		}
		if strings.HasPrefix(relPath, "/") {
			return fmt.Errorf("module path %q must not start with /", relPath)
		}
		cleanRel := path.Clean(relPath)
		if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
			return fmt.Errorf("module path %q is not canonical", relPath)
		}
		if strings.ToLower(path.Ext(relPath)) != ".wasm" {
			return nil
		}

		requestPath := "/modules/" + cleanRel
		if _, exists := assets[requestPath]; exists {
			return fmt.Errorf("duplicate module request path %q", requestPath)
		}

		body, err := os.ReadFile(fullPath)
		if err != nil {
			return err
		}
		assets[requestPath] = moduleAsset{
			body:        body,
			contentType: "application/wasm",
		}
		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	requestPaths := make([]string, 0, len(assets))
	for requestPath := range assets {
		requestPaths = append(requestPaths, requestPath)
	}
	sort.Strings(requestPaths)
	return assets, requestPaths, nil
}

func loadFormModules(formsRoot string) (map[string][]byte, map[string][32]byte, error) {
	modules := make(map[string][]byte)
	digests := make(map[string][32]byte)
	if formsRoot == "" {
		return modules, digests, nil
	}

	modulePaths := make(map[string]string)
	err := walkFilesFollowingSymlinks(formsRoot, "form", func(fullPath string, _ fs.FileInfo) error {
		relPath, err := filepath.Rel(formsRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if !utf8.ValidString(relPath) {
			return fmt.Errorf("form path %q must be valid UTF-8", relPath)
		}
		if strings.HasPrefix(relPath, "/") {
			return fmt.Errorf("form path %q must not start with /", relPath)
		}
		cleanRel := path.Clean(relPath)
		if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
			return fmt.Errorf("form path %q is not canonical", relPath)
		}
		if strings.ToLower(path.Ext(relPath)) != ".wasm" {
			return nil
		}

		formName := strings.TrimSuffix(relPath, path.Ext(relPath))
		if formName == "" {
			return fmt.Errorf("form path %q must include a name before .wasm", relPath)
		}

		if prev, exists := modulePaths[formName]; exists {
			return fmt.Errorf("duplicate form module name %q in %q and %q", formName, prev, fullPath)
		}

		body, err := os.ReadFile(fullPath)
		if err != nil {
			return err
		}
		modules[formName] = body
		digests[formName] = sha256.Sum256(body)
		modulePaths[formName] = fullPath
		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	return modules, digests, nil
}

func closePipelines(ctx context.Context, pipelines map[string]*qinternal.Pipeline) {
	for _, p := range pipelines {
		_ = p.Close(ctx)
	}
}

func buildDevETag(sourceDigest [32]byte, recipeDigests [][32]byte, formDigests [][32]byte) string {
	if len(recipeDigests) == 0 && len(formDigests) == 0 {
		return fmt.Sprintf("\"%x\"", sourceDigest)
	}
	h := sha256.New()
	_, _ = h.Write(sourceDigest[:])
	for _, digest := range recipeDigests {
		_, _ = h.Write(digest[:])
	}
	for _, digest := range formDigests {
		_, _ = h.Write(digest[:])
	}
	return fmt.Sprintf("\"%x\"", h.Sum(nil))
}

func withExecutionTimeout(ctx context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	if timeout <= 0 {
		return ctx, func() {}
	}
	return wasmruntime.WithExecutionTimeout(ctx, timeout)
}

func processApplicationWARCArchive(ctx context.Context, pipeline *qinternal.Pipeline, warc []byte, requestID uint64) ([]byte, error) {
	if pipeline == nil {
		return warc, nil
	}
	input := qinternal.NewRawBytesContentWithType(warc, applicationWARCRecipeMIME)
	result, err := pipeline.Process(ctx, input, requestID)
	if err != nil {
		return nil, err
	}
	_, output, err := ensureRawContent(result)
	if err != nil {
		return nil, err
	}
	return output, nil
}

func transformRouteResponseWithApplicationWARC(
	ctx context.Context,
	pipeline *qinternal.Pipeline,
	requestPath string,
	response qinternal.InProcessHTTPResponse,
	requestID uint64,
) (qinternal.InProcessHTTPResponse, error) {
	if pipeline == nil {
		return response, nil
	}
	requestURI := buildWARCRequestURI("qip.local", requestPath)
	record, err := buildMinimalWARCResponseRecord(requestURI, response)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("failed to build WARC record for %q: %w", requestPath, err)
	}
	transformedWARC, err := processApplicationWARCArchive(ctx, pipeline, record, requestID)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, err
	}
	transformedResponse, err := extractFirstWARCResponseRecord(transformedWARC)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("failed to parse transformed WARC response for %q: %w", requestPath, err)
	}
	return transformedResponse, nil
}

func buildWARCRequestURI(host string, requestPath string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		host = "qip.local"
	}
	requestPath = strings.TrimSpace(requestPath)
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}
	return "http://" + host + requestPath
}

func buildMinimalWARCResponseRecord(targetURI string, response qinternal.InProcessHTTPResponse) ([]byte, error) {
	targetURI = strings.TrimSpace(targetURI)
	if targetURI == "" {
		return nil, errors.New("target URI must not be empty")
	}

	payload := buildWARCHTTPResponsePayload(response)
	var buf bytes.Buffer
	buf.WriteString("WARC/1.0\r\n")
	buf.WriteString("WARC-Type: response\r\n")
	buf.WriteString("WARC-Target-URI: ")
	buf.WriteString(targetURI)
	buf.WriteString("\r\n")
	buf.WriteString("WARC-Date: ")
	buf.WriteString(time.Now().UTC().Format(time.RFC3339))
	buf.WriteString("\r\n")
	buf.WriteString("WARC-Record-ID: <urn:uuid:qip-dev-response>\r\n")
	buf.WriteString("Content-Type: application/http; msgtype=response\r\n")
	buf.WriteString("Content-Length: ")
	buf.WriteString(strconv.Itoa(len(payload)))
	buf.WriteString("\r\n\r\n")
	buf.Write(payload)
	buf.WriteString("\r\n\r\n")
	return buf.Bytes(), nil
}

func buildWARCHTTPResponsePayload(response qinternal.InProcessHTTPResponse) []byte {
	statusCode := response.StatusCode
	if statusCode == 0 {
		statusCode = http.StatusOK
	}
	statusText := http.StatusText(statusCode)
	if statusText == "" {
		statusText = "Status"
	}

	headers := response.Header.Clone()
	if headers == nil {
		headers = make(http.Header)
	}
	if headers.Get("Content-Length") == "" {
		headers.Set("Content-Length", strconv.Itoa(len(response.Body)))
	}

	keys := make([]string, 0, len(headers))
	for key := range headers {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var payload bytes.Buffer
	fmt.Fprintf(&payload, "HTTP/1.1 %d %s\r\n", statusCode, statusText)
	for _, key := range keys {
		for _, value := range headers[key] {
			payload.WriteString(key)
			payload.WriteString(": ")
			payload.WriteString(value)
			payload.WriteString("\r\n")
		}
	}
	payload.WriteString("\r\n")
	payload.Write(response.Body)
	return payload.Bytes()
}

func extractFirstWARCResponseRecord(warc []byte) (qinternal.InProcessHTTPResponse, error) {
	cursor := 0
	for cursor < len(warc) {
		for cursor < len(warc) && (warc[cursor] == '\r' || warc[cursor] == '\n') {
			cursor++
		}
		if cursor >= len(warc) {
			break
		}

		headerEnd := findHeaderBlockEnd(warc[cursor:])
		if headerEnd == -1 {
			return qinternal.InProcessHTTPResponse{}, errors.New("WARC header terminator not found")
		}
		headerBlock := warc[cursor : cursor+headerEnd]

		warcType := ""
		contentLength := -1
		lines := bytes.Split(headerBlock, []byte("\n"))
		for i, rawLine := range lines {
			line := bytes.TrimSpace(rawLine)
			if len(line) == 0 || i == 0 {
				continue
			}
			colon := bytes.IndexByte(line, ':')
			if colon <= 0 {
				continue
			}
			key := strings.TrimSpace(string(line[:colon]))
			value := strings.TrimSpace(string(line[colon+1:]))
			switch {
			case strings.EqualFold(key, "WARC-Type"):
				warcType = value
			case strings.EqualFold(key, "Content-Length"):
				n, err := strconv.Atoi(value)
				if err != nil || n < 0 {
					return qinternal.InProcessHTTPResponse{}, fmt.Errorf("invalid WARC Content-Length %q", value)
				}
				contentLength = n
			}
		}
		if contentLength < 0 {
			return qinternal.InProcessHTTPResponse{}, errors.New("WARC record is missing Content-Length")
		}

		payloadStart := cursor + headerEnd
		payloadEnd := payloadStart + contentLength
		if payloadEnd > len(warc) {
			return qinternal.InProcessHTTPResponse{}, errors.New("WARC record payload exceeds archive length")
		}
		payload := warc[payloadStart:payloadEnd]
		if strings.EqualFold(warcType, "response") {
			return parseWARCHTTPResponsePayload(payload)
		}
		cursor = payloadEnd
	}
	return qinternal.InProcessHTTPResponse{}, errors.New("WARC archive has no response record")
}

func parseWARCHTTPResponsePayload(payload []byte) (qinternal.InProcessHTTPResponse, error) {
	headerEnd := findHeaderBlockEnd(payload)
	if headerEnd == -1 {
		return qinternal.InProcessHTTPResponse{}, errors.New("HTTP payload header terminator not found")
	}
	headerBlock := payload[:headerEnd]
	body := append([]byte(nil), payload[headerEnd:]...)

	lines := bytes.Split(headerBlock, []byte("\n"))
	if len(lines) == 0 {
		return qinternal.InProcessHTTPResponse{}, errors.New("HTTP payload is missing status line")
	}
	statusLine := strings.TrimSpace(string(lines[0]))
	parts := strings.Fields(statusLine)
	if len(parts) < 2 {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("invalid HTTP status line %q", statusLine)
	}
	statusCode, err := strconv.Atoi(parts[1])
	if err != nil || statusCode < 100 {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("invalid HTTP status code in %q", statusLine)
	}

	headers := make(http.Header)
	for _, rawLine := range lines[1:] {
		line := bytes.TrimSpace(rawLine)
		if len(line) == 0 {
			continue
		}
		colon := bytes.IndexByte(line, ':')
		if colon <= 0 {
			continue
		}
		key := textproto.CanonicalMIMEHeaderKey(strings.TrimSpace(string(line[:colon])))
		if key == "" {
			continue
		}
		value := strings.TrimSpace(string(line[colon+1:]))
		headers.Add(key, value)
	}
	if headers.Get("Content-Length") == "" {
		headers.Set("Content-Length", strconv.Itoa(len(body)))
	}

	return qinternal.InProcessHTTPResponse{
		StatusCode: statusCode,
		Header:     headers,
		Body:       body,
	}, nil
}

func findHeaderBlockEnd(data []byte) int {
	if idx := bytes.Index(data, []byte("\r\n\r\n")); idx >= 0 {
		return idx + 4
	}
	if idx := bytes.Index(data, []byte("\n\n")); idx >= 0 {
		return idx + 2
	}
	return -1
}

func injectQIPFormRuntime(body []byte, formModules map[string][]byte, formDigests map[string][32]byte) ([]byte, [][32]byte, error) {
	formNames, err := extractQIPFormNames(body)
	if err != nil {
		return nil, nil, err
	}
	if len(formNames) == 0 {
		return body, nil, nil
	}
	if len(formModules) == 0 {
		return nil, nil, errors.New("qip-form tags detected, but no form modules are loaded (pass --forms <forms_dir>)")
	}

	usedDigests := make([][32]byte, len(formNames))
	for i, name := range formNames {
		if _, ok := formModules[name]; !ok {
			return nil, nil, fmt.Errorf("qip-form name %q has no matching module in --forms", name)
		}
		digest, ok := formDigests[name]
		if !ok {
			return nil, nil, fmt.Errorf("qip-form name %q is missing digest metadata", name)
		}
		usedDigests[i] = digest
	}

	script, err := buildQIPFormInlineScript(formNames, formModules)
	if err != nil {
		return nil, nil, err
	}
	return injectInlineModuleScript(body, script), usedDigests, nil
}

func extractQIPFormNames(body []byte) ([]string, error) {
	tags := qipFormTagPattern.FindAll(body, -1)
	if len(tags) == 0 {
		return nil, nil
	}

	seen := make(map[string]struct{}, len(tags))
	names := make([]string, 0, len(tags))
	for _, tagBytes := range tags {
		matches := qipFormNamePattern.FindSubmatch(tagBytes)
		if len(matches) == 0 {
			return nil, errors.New("<qip-form> tag is missing required name attribute")
		}

		var rawName string
		for i := 1; i <= 3; i++ {
			if len(matches[i]) > 0 {
				rawName = string(matches[i])
				break
			}
		}
		name := strings.TrimSpace(html.UnescapeString(rawName))
		if name == "" {
			return nil, errors.New("<qip-form> name attribute must not be empty")
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		names = append(names, name)
	}

	sort.Strings(names)
	return names, nil
}

func buildQIPFormInlineScript(formNames []string, formModules map[string][]byte) ([]byte, error) {
	var b strings.Builder
	b.Grow(4096 + len(formNames)*256)
	b.WriteString("<script type=\"module\">\n")
	b.WriteString("const qipFormModules = new Map([\n")
	for _, name := range formNames {
		moduleBytes := formModules[name]
		nameJSON, err := json.Marshal(name)
		if err != nil {
			return nil, err
		}
		encodedJSON, err := json.Marshal(base64.StdEncoding.EncodeToString(moduleBytes))
		if err != nil {
			return nil, err
		}
		b.WriteString("  [")
		b.Write(nameJSON)
		b.WriteString(", ")
		b.Write(encodedJSON)
		b.WriteString("],\n")
	}
	b.WriteString("]);\n")
	b.WriteString(qipFormClientRuntimeModuleJS)
	b.WriteString("\n</script>")
	return []byte(b.String()), nil
}

func injectInlineModuleScript(body []byte, script []byte) []byte {
	lower := strings.ToLower(string(body))
	idx := strings.LastIndex(lower, "</body>")
	if idx == -1 {
		out := make([]byte, 0, len(body)+len(script))
		out = append(out, body...)
		out = append(out, script...)
		return out
	}

	out := make([]byte, 0, len(body)+len(script))
	out = append(out, body[:idx]...)
	out = append(out, script...)
	out = append(out, body[idx:]...)
	return out
}

func injectQIPPreviewRuntime(body []byte) []byte {
	if !qipPreviewTagPattern.Match(body) {
		return body
	}
	var b strings.Builder
	b.Grow(len(qipPreviewClientRuntimeModuleJS) + 64)
	b.WriteString("<script type=\"module\">\n")
	b.WriteString(qipPreviewClientRuntimeModuleJS)
	b.WriteString("\n</script>")
	return injectInlineModuleScript(body, []byte(b.String()))
}

//go:embed embedded/qip-form-client-runtime.js
var qipFormClientRuntimeModuleJS string

//go:embed embedded/qip-preview-client-runtime.js
var qipPreviewClientRuntimeModuleJS string

func devResponseContentType(sourceMIME string, recipesApplied bool, output qinternal.Content, body []byte) string {
	if recipesApplied && sourceMIME == "text/markdown" {
		return "text/html; charset=utf-8"
	}
	if output.Encoding() == qinternal.EncodingBMP {
		return "image/bmp"
	}
	if output.Encoding() == qinternal.EncodingRawBytes {
		if isICOBytes(body) {
			return "image/x-icon"
		}
		if _, _, err := qinternal.GetBMPDimensions(body); err == nil {
			return "image/bmp"
		}
	}
	if sourceMIME == "" {
		return "application/octet-stream"
	}
	if strings.HasPrefix(sourceMIME, "text/") {
		return sourceMIME + "; charset=utf-8"
	}
	return sourceMIME
}

func shouldApplyRecipesForRequestPath(requestPath string, route qinternal.ContentRoute, recipeChains map[string]*qinternal.Pipeline) bool {
	if recipeChains == nil || recipeChains[route.SourceMIME] == nil {
		return false
	}
	if route.SourceMIME != "text/markdown" {
		return true
	}

	switch strings.ToLower(path.Ext(requestPath)) {
	case ".md", ".markdown":
		return false
	default:
		return true
	}
}

func inferRecipeOutputContentTypes(ctx context.Context, recipeChains map[string]*qinternal.Pipeline) map[string]string {
	out := make(map[string]string, len(recipeChains))
	for mimeType, pipeline := range recipeChains {
		contentType, err := inferPipelineOutputContentType(ctx, pipeline, mimeType)
		if err != nil || contentType == "" {
			continue
		}
		out[mimeType] = contentType
	}
	return out
}

func inferPipelineOutputContentType(ctx context.Context, pipeline *qinternal.Pipeline, initialContentType string) (string, error) {
	if pipeline == nil {
		return "", nil
	}
	currentContentType := normalizeIncomingContentType(initialContentType)
	for i, stage := range pipeline.Stages {
		runStage, ok := stage.(*qinternal.RunStage)
		if !ok {
			// Only run stages can declare output_content_type_ptr.
			currentContentType = ""
			continue
		}
		driver, ok := runStage.Driver.(*wasmRunDriver)
		if !ok {
			currentContentType = ""
			continue
		}

		outputType, hasOutputType, outputEncoding, hasOutputEncoding, err := inspectRunModuleOutputContract(
			ctx,
			driver.runtime,
			driver.compiled,
			fmt.Sprintf("inspect-output-%d", i),
		)
		if err != nil {
			return "", err
		}
		if hasOutputType {
			currentContentType = outputType
			continue
		}
		if hasOutputEncoding && (outputEncoding == dataEncodingUTF8 || outputEncoding == dataEncodingRaw) {
			continue
		}
		currentContentType = ""
	}
	return currentContentType, nil
}

func inspectRunModuleOutputContract(
	ctx context.Context,
	runtime wazero.Runtime,
	compiled wazero.CompiledModule,
	moduleName string,
) (outputType string, hasOutputType bool, outputEncoding dataEncoding, hasOutputEncoding bool, err error) {
	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName(moduleName))
	if err != nil {
		return "", false, 0, false, errors.New("wasm module could not be instantiated")
	}
	defer func() { _ = mod.Close(ctx) }()

	outputType, hasOutputType, err = readOptionalModuleContentType(ctx, mod, "output")
	if err != nil {
		return "", false, 0, false, err
	}

	_, hasOutputPtr, err := getExportedValue(ctx, mod, "output_ptr")
	if err != nil {
		return "", false, 0, false, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !hasOutputPtr {
		return outputType, hasOutputType, 0, false, nil
	}

	if _, ok, err := getExportedValue(ctx, mod, "output_utf8_cap"); err != nil {
		return "", false, 0, false, wasmruntime.HumanizeExecutionError(ctx, err)
	} else if ok {
		return outputType, hasOutputType, dataEncodingUTF8, true, nil
	}
	if _, ok, err := getExportedValue(ctx, mod, "output_bytes_cap"); err != nil {
		return "", false, 0, false, wasmruntime.HumanizeExecutionError(ctx, err)
	} else if ok {
		return outputType, hasOutputType, dataEncodingRaw, true, nil
	}
	if _, ok, err := getExportedValue(ctx, mod, "output_i32_cap"); err != nil {
		return "", false, 0, false, wasmruntime.HumanizeExecutionError(ctx, err)
	} else if ok {
		return outputType, hasOutputType, dataEncodingArrayI32, true, nil
	}
	return outputType, hasOutputType, 0, false, nil
}

type stageKind uint8

const (
	stageKindRun stageKind = iota
	stageKindTile
)

func buildPipeline(ctx context.Context, modules []string, opts options) (*qinternal.Pipeline, error) {
	specs := make([]moduleSpec, len(modules))
	for i, modulePath := range modules {
		specs[i] = moduleSpec{
			path:     modulePath,
			uniforms: make(map[string]string),
		}
	}
	return buildPipelineFromSpecs(ctx, specs, opts)
}

func buildPipelineFromSpecs(ctx context.Context, specs []moduleSpec, opts options) (*qinternal.Pipeline, error) {
	if len(specs) == 0 {
		return &qinternal.Pipeline{}, nil
	}

	runtime := wasmruntime.New(ctx)

	type moduleInfo struct {
		path     string
		cm       wazero.CompiledModule
		kind     stageKind
		uniforms map[string]string
	}
	infos := make([]moduleInfo, len(specs))

	var stages []qinternal.Stage
	cleanup := func() {
		for _, stage := range stages {
			_ = stage.Close(ctx)
		}
		for _, info := range infos {
			if info.cm != nil {
				_ = info.cm.Close(ctx)
			}
		}
		_ = runtime.Close(ctx)
	}

	for i, spec := range specs {
		body, err := readModulePath(spec.path, opts)
		if err != nil {
			cleanup()
			return nil, err
		}
		cm, err := runtime.CompileModule(ctx, body)
		if err != nil {
			cleanup()
			return nil, fmt.Errorf("wasm module %q could not be compiled: %w", spec.path, err)
		}

		kind := stageKindRun
		if _, ok := cm.ExportedFunctions()["tile_rgba_f32_64x64"]; ok {
			kind = stageKindTile
		}
		infos[i] = moduleInfo{path: spec.path, cm: cm, kind: kind, uniforms: spec.uniforms}
	}

	for i := 0; i < len(infos); {
		info := infos[i]
		if info.kind == stageKindRun {
			driver := &wasmRunDriver{
				runtime:                      runtime,
				compiled:                     info.cm,
				instanceName:                 fmt.Sprintf("stage-%d", i),
				modulePath:                   info.path,
				opts:                         opts,
				uniforms:                     info.uniforms,
				allowMissingInputContentType: opts.trustFirstStageContent && i == 0,
			}
			stages = append(stages, &qinternal.RunStage{Driver: driver})
			i++
		} else {
			// Group contiguous tile modules
			var tileDrivers []qinternal.TileModuleDriver
			for i < len(infos) && infos[i].kind == stageKindTile {
				driver := &wasmTileModuleDriver{
					runtime:      runtime,
					compiled:     infos[i].cm,
					instanceName: fmt.Sprintf("tile-%d", i),
					modulePath:   infos[i].path,
					uniforms:     infos[i].uniforms,
				}
				// Pre-instantiate to get halo
				if err := driver.init(ctx); err != nil {
					cleanup()
					return nil, err
				}
				tileDrivers = append(tileDrivers, driver)
				i++
			}
			stages = append(stages, &qinternal.TileGroupStage{Drivers: tileDrivers})
		}
	}

	return &qinternal.Pipeline{
		Stages: stages,
		CloseFunc: func(closeCtx context.Context) error {
			return runtime.Close(closeCtx)
		},
	}, nil
}

type wasmRunDriver struct {
	runtime                      wazero.Runtime
	compiled                     wazero.CompiledModule
	instanceName                 string
	modulePath                   string
	opts                         options
	uniforms                     map[string]string
	allowMissingInputContentType bool
}

func (d *wasmRunDriver) Execute(ctx context.Context, input qinternal.Content, requestID uint64) (qinternal.Content, error) {
	inputBytes, err := qinternal.AsRawBytes(input)
	if err != nil {
		bmp, bmpErr := qinternal.ToBMPContent(input)
		if bmpErr != nil {
			return nil, err
		}
		inputBytes = bmp.RawBytes()
	}

	// Implementation of executeModuleWithInput logic adapted to Content
	exec, err := executeModuleWithInput(
		ctx,
		d.runtime,
		d.compiled,
		inputBytes,
		d.opts,
		d.instanceName,
		d.uniforms,
		qinternal.ContentTypeOf(input),
		d.allowMissingInputContentType,
	)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", d.modulePath, err)
	}

	switch exec.output.encoding {
	case dataEncodingUTF8:
		return qinternal.NewStringContentWithType(string(exec.output.bytes), exec.outputContentType), nil
	case dataEncodingArrayI32:
		return qinternal.NewI32ArrayContentWithType(exec.output.bytes, exec.outputContentType), nil
	default:
		// Check if it's a BMP
		if w, h, err := qinternal.GetBMPDimensions(exec.output.bytes); err == nil {
			return qinternal.NewBMPContentWithType(exec.output.bytes, w, h, exec.outputContentType), nil
		}
		return qinternal.NewRawBytesContentWithType(exec.output.bytes, exec.outputContentType), nil
	}
}

func (d *wasmRunDriver) Close(ctx context.Context) error {
	return d.compiled.Close(ctx)
}

type wasmTileModuleDriver struct {
	runtime      wazero.Runtime
	compiled     wazero.CompiledModule
	instanceName string
	modulePath   string
	uniforms     map[string]string

	mod         api.Module
	tileFunc    api.Function
	uniformFunc api.Function
	inputPtr    uint32
	inputCap    uint64
	haloPx      int
}

func (d *wasmTileModuleDriver) init(ctx context.Context) error {
	mod, err := d.runtime.InstantiateModule(ctx, d.compiled, wazero.NewModuleConfig().WithName(d.instanceName))
	if err != nil {
		return fmt.Errorf("%s: %w", d.modulePath, err)
	}
	d.mod = mod

	stage, err := loadTileStage(ctx, mod)
	if err != nil {
		_ = mod.Close(ctx)
		return fmt.Errorf("%s: %w", d.modulePath, err)
	}

	if err := applyModuleUniforms(ctx, mod, d.uniforms); err != nil {
		_ = mod.Close(ctx)
		return fmt.Errorf("%s: %w", d.modulePath, err)
	}

	d.tileFunc = stage.tileFunc
	d.uniformFunc = stage.uniformFunc
	d.inputPtr = stage.inputPtr
	d.inputCap = stage.inputCap
	if stage.haloFunc != nil {
		values, err := stage.haloFunc.Call(ctx)
		if err != nil {
			_ = mod.Close(ctx)
			return fmt.Errorf("%s: %w", d.modulePath, wasmruntime.HumanizeExecutionError(ctx, err))
		}
		if len(values) > 0 {
			d.haloPx = int(int32(values[0]))
		}
	}
	if d.haloPx < 0 {
		d.haloPx = 0
	}
	return nil
}

func (d *wasmTileModuleDriver) ExecuteTile(ctx context.Context, x, y float32, tilePixels []float32) ([]float32, error) {
	// Convert float32 pixels to bytes for Wasm
	pixelBytes := unsafe.Slice((*byte)(unsafe.Pointer(&tilePixels[0])), len(tilePixels)*4)
	if uint64(len(pixelBytes)) > d.inputCap {
		return nil, fmt.Errorf("%s: %w", d.modulePath, errors.New("tile too large for Wasm module capacity"))
	}

	mem := d.mod.Memory()
	if !mem.Write(d.inputPtr, pixelBytes) {
		return nil, fmt.Errorf("%s: %w", d.modulePath, errors.New("failed to write tile to Wasm memory"))
	}

	if _, err := d.tileFunc.Call(ctx, api.EncodeF32(x), api.EncodeF32(y)); err != nil {
		return nil, fmt.Errorf("%s: %w", d.modulePath, wasmruntime.HumanizeExecutionError(ctx, err))
	}

	outBytes, ok := mem.Read(d.inputPtr, uint32(len(pixelBytes)))
	if !ok {
		return nil, fmt.Errorf("%s: %w", d.modulePath, errors.New("failed to read tile from Wasm memory"))
	}

	// Copy back to float32 slice
	outPixels := make([]float32, len(tilePixels))
	copy(unsafe.Slice((*byte)(unsafe.Pointer(&outPixels[0])), len(outPixels)*4), outBytes)
	return outPixels, nil
}

func (d *wasmTileModuleDriver) Close(ctx context.Context) error {
	if d.mod != nil {
		_ = d.mod.Close(ctx)
	}
	return d.compiled.Close(ctx)
}

func (d *wasmTileModuleDriver) HaloPx() int {
	return d.haloPx
}

func (d *wasmTileModuleDriver) SetImageSize(ctx context.Context, width, height int) error {
	if d.uniformFunc == nil {
		return nil
	}
	if _, err := d.uniformFunc.Call(
		ctx,
		api.EncodeF32(float32(width)),
		api.EncodeF32(float32(height)),
	); err != nil {
		return fmt.Errorf("%s: %w", d.modulePath, wasmruntime.HumanizeExecutionError(ctx, err))
	}
	return nil
}

func formatOutputBytes(output qinternal.Content) ([]byte, error) {
	switch output.Encoding() {
	case qinternal.EncodingRawBytes, qinternal.EncodingUTF8, qinternal.EncodingBMP:
		return qinternal.AsRawBytes(output)
	case qinternal.EncodingI32Array:
		data, err := qinternal.AsRawBytes(output)
		if err != nil {
			return nil, err
		}
		count := len(data) / 4
		var buf bytes.Buffer
		buf.Grow(count * 9)
		for i := 0; i < count; i++ {
			v := binary.LittleEndian.Uint32(data[i*4:])
			fmt.Fprintf(&buf, "%08x\n", v)
		}
		return buf.Bytes(), nil
	default:
		return nil, errors.New("unknown output encoding")
	}
}

func writeRunOutput(result qinternal.Content, outputBytes []byte, outputPath string, opts options) error {
	if outputPath == "" {
		outputPath = "-"
	}
	if outputPath == "-" {
		return writeRunOutputToStdout(result, outputBytes, opts)
	}
	return writeRunOutputToFile(result, outputPath)
}

func writeRunOutputToStdout(result qinternal.Content, outputBytes []byte, opts options) error {
	if result.Encoding() == qinternal.EncodingRawBytes || result.Encoding() == qinternal.EncodingBMP {
		if _, err := os.Stdout.Write(outputBytes); err != nil {
			return fmt.Errorf("error writing raw output: %w", err)
		}
		return nil
	}

	if result.Encoding() == qinternal.EncodingUTF8 {
		fmt.Printf("%s\n", outputBytes)
		return nil
	}

	if result.Encoding() == qinternal.EncodingI32Array {
		if opts.verbose {
			fmt.Fprintln(os.Stderr, string(outputBytes))
		}

		count := len(outputBytes) / 4
		if count < 1 {
			return nil
		}

		bufSize := count * 9
		writer := bufio.NewWriterSize(os.Stdout, bufSize)
		defer func() { _ = writer.Flush() }()

		for i := 0; i < count; i++ {
			v := binary.LittleEndian.Uint32(outputBytes[i*4:])
			if opts.verbose {
				vlogf(opts, "u32: %d", v)
			}
			if _, err := fmt.Fprintf(writer, "%08x\n", v); err != nil {
				return fmt.Errorf("error writing i32 output: %w", err)
			}
		}
		return nil
	}

	return fmt.Errorf("unknown output encoding %v", result.Encoding())
}

func writeRunOutputToFile(result qinternal.Content, outputPath string) error {
	var data []byte

	if wantsImageReencode(outputPath) {
		decodedImage, err := decodeRunOutputImage(result)
		if err != nil {
			return err
		}
		data, err = encodeImageForOutputPath(decodedImage, outputPath)
		if err != nil {
			return err
		}
	} else {
		formattedOutput, err := formatOutputBytes(result)
		if err != nil {
			return err
		}
		data = formattedOutput
	}

	if err := os.WriteFile(outputPath, data, 0o644); err != nil {
		return fmt.Errorf("error writing output file: %w", err)
	}
	return nil
}

func wantsImageReencode(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".png", ".jpg", ".jpeg", ".bmp":
		return true
	default:
		return false
	}
}

func decodeRunOutputImage(output qinternal.Content) (image.Image, error) {
	outputBytes, err := qinternal.AsRawBytes(output)
	if err != nil {
		return nil, fmt.Errorf("cannot decode pipeline output as image: %w", err)
	}
	if len(outputBytes) == 0 {
		return nil, errors.New("cannot decode empty pipeline output as image")
	}

	contentType := normalizeIncomingContentType(qinternal.ContentTypeOf(output))

	if output.Encoding() == qinternal.EncodingBMP || (len(outputBytes) >= 2 && outputBytes[0] == 'B' && outputBytes[1] == 'M') {
		bmp, decodeErr := decodeBMP(outputBytes)
		if decodeErr != nil {
			return nil, fmt.Errorf("could not decode BMP output: %w", decodeErr)
		}
		return bmp, nil
	}

	decodedImage, _, decodeErr := image.Decode(bytes.NewReader(outputBytes))
	if decodeErr == nil {
		return decodedImage, nil
	}

	if strings.HasPrefix(contentType, "image/") {
		return nil, fmt.Errorf("could not decode output image (%s): %w", contentType, decodeErr)
	}

	return nil, fmt.Errorf("cannot encode non-image output as image (encoding=%v, content_type=%q)", output.Encoding(), contentType)
}

func encodeImageForOutputPath(img image.Image, outputPath string) ([]byte, error) {
	ext := strings.ToLower(filepath.Ext(outputPath))
	var out bytes.Buffer

	switch ext {
	case ".png":
		encoder := png.Encoder{CompressionLevel: png.NoCompression}
		if err := encoder.Encode(&out, img); err != nil {
			return nil, err
		}
	case ".jpg", ".jpeg":
		if err := jpeg.Encode(&out, img, &jpeg.Options{Quality: 95}); err != nil {
			return nil, err
		}
	case ".bmp":
		rgbaImage, err := ensureRGBAImage(img)
		if err != nil {
			return nil, err
		}
		bmp, err := encodeBMP(rgbaImage)
		if err != nil {
			return nil, err
		}
		return bmp, nil
	default:
		return nil, fmt.Errorf("unsupported output image extension %q (supported: .png, .jpg, .jpeg, .bmp)", ext)
	}

	return out.Bytes(), nil
}

func ensureRGBAImage(img image.Image) (*image.RGBA, error) {
	if img == nil {
		return nil, errors.New("image is nil")
	}

	if rgba, ok := img.(*image.RGBA); ok {
		return rgba, nil
	}

	bounds := img.Bounds()
	rgba := image.NewRGBA(bounds)
	draw.Draw(rgba, bounds, img, bounds.Min, draw.Src)
	return rgba, nil
}

func ensureRawContent(content qinternal.Content) (qinternal.Content, []byte, error) {
	if data, err := qinternal.AsRawBytes(content); err == nil {
		return content, data, nil
	}

	bmp, err := qinternal.ToBMPContent(content)
	if err != nil {
		return nil, nil, err
	}

	data := bmp.RawBytes()
	return bmp, data, nil
}

func isICOBytes(data []byte) bool {
	if len(data) < 22 {
		return false
	}
	if binary.LittleEndian.Uint16(data[0:2]) != 0 {
		return false
	}
	icoType := binary.LittleEndian.Uint16(data[2:4])
	if icoType != 1 {
		return false
	}
	count := binary.LittleEndian.Uint16(data[4:6])
	if count == 0 {
		return false
	}
	dirSize := 6 + int(count)*16
	if len(data) < dirSize {
		return false
	}

	// Validate the first directory entry payload bounds.
	imageSize := binary.LittleEndian.Uint32(data[14:18])
	imageOffset := binary.LittleEndian.Uint32(data[18:22])
	if imageSize == 0 {
		return false
	}
	if imageOffset < uint32(dirSize) {
		return false
	}
	if imageOffset > uint32(len(data)) {
		return false
	}
	if imageSize > uint32(len(data))-imageOffset {
		return false
	}

	return true
}

func writeDevError(w http.ResponseWriter, err error) {
	ts := time.Now().Format(time.RFC3339)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusInternalServerError)
	_, _ = fmt.Fprintf(w, "<!doctype html><meta charset=\"utf-8\"><title>qip dev error</title><pre>%s\n%s</pre>", ts, html.EscapeString(err.Error()))
}

func formatDurationParts(total time.Duration, moduleDurations []time.Duration, instantiationDurations []time.Duration) string {
	totalMs := total.Milliseconds()
	if len(moduleDurations) == 0 {
		return fmt.Sprintf("duration_ms=%d", totalMs)
	}
	var b strings.Builder
	b.Grow(60 + len(moduleDurations)*6)
	b.WriteString("duration_ms=")
	b.WriteString(strconv.FormatInt(totalMs, 10))
	b.WriteString(" instantiation_ms=")
	b.WriteString(strconv.FormatInt(sumDurations(instantiationDurations), 10))
	b.WriteString(" module_durations_ms=[")
	for i, part := range moduleDurations {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatInt(part.Milliseconds(), 10))
	}
	b.WriteByte(']')
	return b.String()
}

func sumDurations(values []time.Duration) int64 {
	var total int64
	for _, v := range values {
		total += v.Milliseconds()
	}
	return total
}
