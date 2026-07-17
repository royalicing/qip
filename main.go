package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"html"
	"image"
	"image/draw"
	"image/jpeg"
	"image/png"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unsafe"

	qcmd "github.com/royalicing/qip/cmd"
	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasminspect"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

type dataEncoding uint8

const (
	dataEncodingRaw dataEncoding = iota
	dataEncodingUTF8
)

const tileSize = 64
const applicationWARCRecipeMIME = "application/warc"

const (
	defaultRouteRecipeTimeout        = 500 * time.Millisecond
	defaultRouteWARCTransformTimeout = 5 * time.Second
)

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
	traceWith              string
	modulePolicy           wasminspect.ModulePolicy
}

func applyModulePolicyFlags(opts *options, maxMemoryBytes uint64, allowMemoryGrow bool) error {
	if allowMemoryGrow && maxMemoryBytes == 0 {
		return errors.New("--allow-memory-grow requires --max-memory <bytes>")
	}
	opts.modulePolicy.MaxMemoryBytes = maxMemoryBytes
	if !allowMemoryGrow {
		opts.modulePolicy.RejectOpcodes = []wasminspect.InstructionOpcode{wasminspect.OpcodeMemoryGrow}
	}
	return nil
}

const usageMain = "Usage: qip <command> [args]\n\nCommands:\n  run      Run a chain of QIP components on input\n  bench    Compare one or more QIP components for output parity and performance\n  score    Statically score wasm module control-flow and call cost\n  image    Run wasm filters on an input image\n  comply   Validate component ABI and run compliance components\n  dev      Start a dev server for a content directory with optional recipes\n  router   Resolve routed paths and export route artifacts\n  form     Run an interactive QIP form component in the terminal\n  help     Show command help"
const usageRun = "Usage: qip run [-v] [-i <input>] [-o <output file or ->] [--timeout-ms <ms>] [--max-memory <bytes>] [--allow-memory-grow] <QIP component URL or file> [?key=value[&key2=value2...] ...] ..."
const usageBench = "Usage: qip bench -i <input> [-r <benchmark runs> | --benchtime=<duration>] [--timeout-ms <ms>] [--max-memory <bytes>] [--allow-memory-grow] <component1> [component2 ...]"
const usageScore = "Usage: qip score <component1.wasm> [component2.wasm ...]"
const usageImage = "Usage: qip image -i <input image path or -> -o <output image path> [--timeout-ms <ms>] [--max-memory <bytes>] [--allow-memory-grow] [-v] <QIP component URL or file> [?key=value[&key2=value2...] ...] ..."
const usageComply = "Usage: qip comply <impl.wasm> [--with <compliance.wasm> ...] [--profile strict] [--seed <n>] [--legacy] [-v|--verbose]"
const usageDev = "Usage: qip dev <content_dir> [--recipes <recipes_dir>] [--components <components_dir>] [--mode <dev|prod>] [--view-source] [-p <port>] [-v|--verbose]"
const usageRoute = "Usage: qip router <subcommand> [args]\n\nSubcommands:\n  get      Resolve one GET path through the dev router and print the result\n  head     Resolve one HEAD path through the dev router and print headers\n  list     List routed paths and content types\n  warc     Archive the routed site and write a minimal WARC file"
const usageRouteGet = "Usage: qip router get <content_dir> <path> [--recipes <recipes_dir>] [--components <components_dir>] [--mode <dev|prod>] [-v|--verbose]"
const usageRouteHead = "Usage: qip router head <content_dir> <path> [--recipes <recipes_dir>] [--components <components_dir>] [--mode <dev|prod>] [-v|--verbose]"
const usageRouteList = "Usage: qip router list <content_dir> [--recipes <recipes_dir>] [--components <components_dir>] [--mode <dev|prod>] [-v|--verbose]"
const usageRouteWarc = "Usage: qip router warc <content_dir> [--recipes <recipes_dir>] [--components <components_dir>] [--mode <dev|prod>] [--host <host>] [--view-source] [-o <warc file or ->] [-v|--verbose]"
const usageForm = "Usage: qip form [-v|--verbose] <QIP form component URL or file>"
const usageHelp = "Usage: qip help [command]"

const helpRun = "Usage: qip run [-v] [-i <input>] [-o <output file or ->] [--timeout-ms <ms>] [--trace-with <application/wasm component>] [--max-memory <bytes>] [--allow-memory-grow] <QIP component URL or file> [?key=value[&key2=value2...] ...] ...\n\nQIP component contracts:\n  Run mode:\n    - Exports render(input_size), input_ptr, and input_utf8_cap or input_bytes_cap\n    - Exports output_ptr and output_utf8_cap or output_bytes_cap\n    - Optional uniforms: uniform_set_<key>(value)\n  Image mode:\n    - Exports tile_rgba32float_64x64, input_ptr, input_bytes_cap\n    - Optional: uniform_set_width_and_height, calculate_halo_px\n\nOutput:\n  - Default output is stdout.\n  - Use -o <path> to write to a file.\n  - If -o ends with .png/.jpg/.jpeg/.bmp and pipeline output is an image,\n    qip re-encodes to the requested output image format.\n\nModule policy:\n  - Modules containing memory.grow are rejected by default.\n  - --allow-memory-grow permits growth and requires --max-memory <bytes>.\n  - --max-memory rejects modules whose declared memory minimum or maximum exceeds the byte cap.\n    A module with memory but no declared maximum is rejected when this flag is set.\n\nTracing:\n  - --trace-with runs a Wasm-to-Wasm instrumentation component after a trap,\n    then retries the failing module with qip_trace.before_load, before_store,\n    and after_store imports to report recent memory events.\n\nUniform args:\n  Place a query string immediately after a component path to set that component's uniforms.\n  Quote the full query arg in your shell (for example, to avoid '&' splitting).\n  Example: modules/utf8/text-to-bmp.wasm '?cols=120&leading=24'\n  Example: modules/utf8/text-to-path-svg-dejavu-sans-mono.wasm '?width=900&height=400&font_size=48'\n\nComposition:\n  If a component exports tile_rgba32float_64x64, qip run composes a contiguous image stage block.\n  Input to that block must be BMP bytes and the block outputs BMP bytes.\n  Run stages may follow and will receive BMP bytes.\n\nExample:\n  echo '<svg width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"#d52b1e\" /><rect x=\"13\" y=\"6\" width=\"6\" height=\"20\" fill=\"#ffffff\" /><rect x=\"6\" y=\"13\" width=\"20\" height=\"6\" fill=\"#ffffff\" /></svg>' | ./qip run -o out.ico modules/image/svg+xml/svg-rasterize.wasm modules/image/bmp/bmp-double.wasm modules/image/bmp/bmp-to-ico.wasm"
const helpComply = `Usage: qip comply <impl.wasm> [--with <compliance.wasm> ...] [--profile strict] [--seed <n>] [--legacy] [-v|--verbose]

What qip comply does:
  1) Base ABI validation on impl.wasm (always):
     - impl must export memory
     - detects component kind: render, tile, or render+tile
     - render kind requires:
         render(i32) -> i32
         input_ptr (global i32 or function () -> i32)
         input_utf8_cap or input_bytes_cap (global i32 or function () -> i32)
     - tile kind requires:
         tile_rgba32float_64x64(f32, f32) -> ()
         input_ptr (global i32 or function () -> i32)
         input_bytes_cap (global i32 or function () -> i32)

  2) Static qip contract checks (always, when qip exports are present):
     - qip contract functions (for example input_ptr/output_ptr/caps) must be
       vanilla instruction sequences with no calls, loops, or dynamic control flow
     - qip contract globals must be constant init expressions (no global.get dependency)

  3) Executes each --with compliance component:
     - qip instantiates impl as WebAssembly module name "impl"
     - all compliance components run in parallel
     - all must pass

Compliance component contract (what to implement):
  Required imports/exports:
    - must import impl.memory
    - must export positive() -> i32
  Optional:
    - export negative() -> i32
    - import qip.render_must_trap(i32) -> i32 for negative tests that expect trap

Status convention:
  - return > 0 to pass
  - return <= 0 to fail
  - positive() trap always fails
  - if negative() exists, it runs on a fresh impl instance
  - negative() returning <= 0 fails (use render_must_trap when trap is expected)

Memory model for compliance components:
  - compliance imports impl.memory, so both components see the same linear memory
  - to test a render component, compliance usually:
      - calls impl.input_ptr() and impl.input_utf8_cap()/input_bytes_cap()
      - writes test input bytes into impl.memory at input_ptr
      - calls impl.render(input_size)
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

Minimal WAT template (render component checker):
  (module
    (import "impl" "memory" (memory 1))
    (import "impl" "input_ptr" (func $input_ptr (result i32)))
    (import "impl" "render" (func $render (param i32) (result i32)))
    (import "impl" "output_ptr" (func $output_ptr (result i32)))

    (func (export "positive") (result i32)
      ;; write input at (call $input_ptr), call $render, compare output, return >0 on pass
      i32.const 1)

    ;; optional negative phase:
    ;; (import "qip" "render_must_trap" (func $render_must_trap (param i32) (result i32)))
    ;; (func (export "negative") (result i32) ...)
  )

Authoring workflow for agents:
  1) Build impl wasm.
  2) Run: qip comply impl.wasm --with compliance.wasm
  3) On failure, inspect printed message/input/expected/actual previews.
  4) Update impl or compliance component and repeat until PASS.`

func main() {
	args := os.Args[1:]

	if len(args) == 0 {
		gameOver(usageMain)
	}

	if args[0] == "-v" || args[0] == "--verbose" {
		gameOver(usageMain)
	}

	if args[0] == "help" || args[0] == "doc" {
		helpCmd(args[1:])
	} else if args[0] == "run" {
		runCmd(args[1:])
	} else if args[0] == "bench" {
		benchCmd(args[1:])
	} else if args[0] == "score" {
		scoreCmd(args[1:])
	} else if args[0] == "image" {
		imageCmd(args[1:])
	} else if args[0] == "comply" {
		complyCmd(args[1:])
	} else if args[0] == "dev" {
		devCmd(args[1:])
	} else if args[0] == "router" {
		routerCmd(args[1:])
	} else if args[0] == "form" {
		formCmd(args[1:])
	} else {
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
	case "score":
		fmt.Println(usageScore)
	case "image":
		fmt.Println(usageImage)
	case "comply":
		fmt.Println(helpComply)
	case "dev":
		fmt.Println(usageDev)
	case "router":
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

func scoreCmd(args []string) {
	if err := qcmd.RunScore(args, qcmd.ScoreConfig{
		UsageScore: usageScore,
		Stdout:     os.Stdout,
		ReadFile:   os.ReadFile,
	}); err != nil {
		gameOver("%v", err)
	}
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
	var maxMemoryBytes uint64
	var allowMemoryGrow bool
	fs.BoolVar(&runVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&runVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputPath, "i", "", "input file path")
	fs.StringVar(&outputPath, "o", "-", "output file path ('-' for stdout)")
	fs.StringVar(&outputPath, "output", "-", "output file path ('-' for stdout)")
	fs.IntVar(&timeoutMS, "timeout-ms", timeoutMS, "per-run timeout in milliseconds")
	fs.StringVar(&opts.traceWith, "trace-with", "", "application/wasm component used to instrument a module after a trap")
	fs.Uint64Var(&maxMemoryBytes, "max-memory", 0, "reject modules whose declared memory exceeds this byte cap")
	fs.BoolVar(&allowMemoryGrow, "allow-memory-grow", false, "allow memory.grow; requires --max-memory")
	if err := fs.Parse(normalizeRunArgs(args)); err != nil {
		gameOver("%s %v", usageRun, err)
	}
	opts.verbose = opts.verbose || runVerbose
	if err := applyModulePolicyFlags(&opts, maxMemoryBytes, allowMemoryGrow); err != nil {
		gameOver("Invalid module policy: %v", err)
	}

	componentInvocations, parseErr := parseComponentInvocations(fs.Args(), "run")
	if parseErr != nil {
		gameOver("Invalid render module args: %v", parseErr)
	}
	if len(componentInvocations) == 0 {
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

	if len(componentInvocations) == 1 {
		handled, bmpBytes, err := tryRunInteractiveModuleFirstFrame(context.Background(), componentInvocations[0], opts, timeoutMS)
		if err != nil {
			gameOver("%v", err)
		}
		if handled {
			result := qinternal.NewRawBytesContentWithType(bmpBytes, "image/bmp")
			if err := writeRunOutput(result, bmpBytes, outputPath, opts); err != nil {
				gameOver("%v", err)
			}
			return
		}
	}

	start := time.Now()
	defer func() {
		if opts.verbose {
			vlogf(opts, "command took %dms", time.Since(start).Milliseconds())
		}
	}()

	pipeline, err := buildPipelineFromInvocations(context.Background(), componentInvocations, opts)
	if err != nil {
		gameOver("%v", err)
	}
	defer pipeline.Close(context.Background())

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
	benchModuleKindInteractive
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
	var maxMemoryBytes uint64
	var allowMemoryGrow bool

	fs.BoolVar(&benchVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&benchVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputPath, "i", "", "input file path ('-' for stdin)")
	fs.IntVar(&benchRuns, "r", benchRuns, "benchmark runs per module")
	fs.StringVar(&benchtimeStr, "benchtime", benchtimeStr, "target measured time per module (e.g. 3s)")
	fs.IntVar(&timeoutMS, "timeout-ms", timeoutMS, "per-run timeout in milliseconds")
	fs.Uint64Var(&maxMemoryBytes, "max-memory", 0, "reject modules whose declared memory exceeds this byte cap")
	fs.BoolVar(&allowMemoryGrow, "allow-memory-grow", false, "allow memory.grow; requires --max-memory")

	if err := fs.Parse(normalizeBenchArgs(args)); err != nil {
		gameOver("%s %v", usageBench, err)
	}
	opts.verbose = benchVerbose
	if err := applyModulePolicyFlags(&opts, maxMemoryBytes, allowMemoryGrow); err != nil {
		gameOver("Invalid module policy: %v", err)
	}

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
	defer runtime.Close(ctx)

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
		_, hasRun := funcs["render"]
		_, hasTile := funcs["tile_rgba32float_64x64"]
		hasInteractive := hasRun &&
			funcs["tick"] != nil &&
			funcs["key_event"] != nil &&
			funcs["pointer_event"] != nil &&
			funcs["render_width_px"] != nil &&
			funcs["render_height_px"] != nil &&
			funcs["output_rgba8_srgb_bytes"] != nil
		switch {
		case hasTile:
			moduleKinds[i] = benchModuleKindTile
		case hasInteractive:
			moduleKinds[i] = benchModuleKindInteractive
		case hasRun:
			moduleKinds[i] = benchModuleKindRun
		default:
			gameOver("bench check failed for %s: Wasm module must export render(i32) -> i32, interactive render/tick exports, or tile_rgba32float_64x64(f32, f32)", modules[i])
		}
		compiled[i] = cm
		defer compiled[i].Close(ctx)
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
	case benchModuleKindInteractive:
		return runBenchInteractiveSample(parent, runtime, compiled, moduleName, timeout)
	default:
		return benchSample{}, contentData{}, errors.New("unknown bench module kind")
	}
}

func runBenchInteractiveSample(
	parent context.Context,
	runtime wazero.Runtime,
	compiled wazero.CompiledModule,
	moduleName string,
	timeout time.Duration,
) (sample benchSample, output contentData, returnErr error) {
	ctx := parent
	cancel := func() {}
	if timeout > 0 {
		ctxWithTimeout, cancelWithTimeout := wasmruntime.WithExecutionTimeout(parent, timeout)
		ctx = ctxWithTimeout
		cancel = cancelWithTimeout
	}
	defer cancel()

	instStart := time.Now()
	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName(moduleName))
	if err != nil {
		returnErr = errors.New("Wasm module could not be instantiated")
		return
	}
	defer mod.Close(ctx)
	sample.instantiation = time.Since(instStart)

	if mod.Memory() == nil {
		returnErr = errors.New("interactive Wasm module must export memory")
		return
	}

	renderWidthVal, _, err := getExportedValue(ctx, mod, "render_width_px")
	if err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	}
	renderHeightVal, _, err := getExportedValue(ctx, mod, "render_height_px")
	if err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	}
	renderWidth := int(int32(renderWidthVal))
	renderHeight := int(int32(renderHeightVal))
	if renderWidth <= 0 || renderHeight <= 0 {
		returnErr = fmt.Errorf("interactive module reported invalid render size %dx%d", renderWidth, renderHeight)
		return
	}
	expectedLen := renderWidth * renderHeight * 4

	outputBytesValue, ok, err := getExportedValue(ctx, mod, "output_rgba8_srgb_bytes")
	if err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	}
	if !ok {
		returnErr = errors.New("interactive module missing output_rgba8_srgb_bytes export")
		return
	}
	if int(int32(outputBytesValue)) != expectedLen {
		returnErr = fmt.Errorf("interactive module output_rgba8_srgb_bytes=%d, expected %d", int(int32(outputBytesValue)), expectedLen)
		return
	}

	outputPtrValue, ok, err := getExportedValue(ctx, mod, "output_ptr")
	if err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	}
	if !ok {
		returnErr = errors.New("interactive module missing output_ptr export")
		return
	}
	outputPtr := uint32(outputPtrValue)

	tickFunc := mod.ExportedFunction("tick")
	renderFunc := mod.ExportedFunction("render")
	if _, err := tickFunc.Call(ctx, 0); err != nil {
		returnErr = fmt.Errorf("tick(0) failed: %w", wasmruntime.HumanizeExecutionError(ctx, err))
		return
	}
	runStart := time.Now()
	renderResult, err := renderFunc.Call(ctx, 0)
	if err != nil {
		returnErr = fmt.Errorf("render(0) failed: %w", wasmruntime.HumanizeExecutionError(ctx, err))
		return
	}
	sample.run = time.Since(runStart)
	sample.total = sample.run
	if len(renderResult) != 1 {
		returnErr = fmt.Errorf("render(0) returned %d values, want 1", len(renderResult))
		return
	}
	outputLen := int(int32(renderResult[0]))
	if outputLen != expectedLen {
		returnErr = fmt.Errorf("render(0) returned %d bytes, expected %d", outputLen, expectedLen)
		return
	}

	outputRaw, ok := mod.Memory().Read(outputPtr, uint32(outputLen))
	if !ok {
		returnErr = errors.New("could not read interactive output frame")
		return
	}
	sample.outputCapBytes = uint64(expectedLen)
	sample.memoryBytes = uint64(mod.Memory().Size())
	return sample, contentData{bytes: slices.Clone(outputRaw), encoding: dataEncodingRaw}, nil
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

func parseComponentInvocations(args []string, commandName string) ([]ComponentInvocation, error) {
	specs := make([]ComponentInvocation, 0, len(args))
	for _, arg := range args {
		if strings.HasPrefix(arg, "?") {
			if len(specs) == 0 {
				return nil, fmt.Errorf("%s uniform query %q must follow a QIP component path", commandName, arg)
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
				last.UniformValues[key] = vals[len(vals)-1]
			}
			continue
		}

		specs = append(specs, ComponentInvocation{
			Source:        arg,
			UniformValues: make(map[string]string),
		})
	}
	return specs, nil
}

func formatCapacityBytes(size uint64) string {
	if size == 0 {
		return "n/a"
	}
	return fmt.Sprintf("%s (%d bytes)", formatBytesIEC(size), size)
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
	default:
		return fmt.Sprintf("unknown(%d)", encoding)
	}
}

func loadTileStage(ctx context.Context, mod api.Module) (tileStage, error) {
	tileFunc := mod.ExportedFunction("tile_rgba32float_64x64")
	if tileFunc == nil {
		return tileStage{}, errors.New("Wasm module must export tile_rgba32float_64x64")
	}
	uniformFunc := mod.ExportedFunction("uniform_set_width_and_height")
	haloFunc := mod.ExportedFunction("calculate_halo_px")
	mem := mod.Memory()
	inputPtrValue, ok, err := getExportedValue(ctx, mod, "input_ptr")
	if err != nil {
		return tileStage{}, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !ok {
		return tileStage{}, errors.New("Wasm module must export input_ptr as global or function")
	}
	inputCap, ok, err := getExportedValue(ctx, mod, "input_bytes_cap")
	if err != nil {
		return tileStage{}, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !ok {
		return tileStage{}, errors.New("Wasm module must export input_bytes_cap as global or function")
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
				return nil, nil, fmt.Errorf("Error running uniform_set_width_and_height: %v", err)
			}
		}
		if stage.haloFunc != nil {
			values, err := stage.haloFunc.Call(ctx)
			if err != nil {
				return nil, nil, fmt.Errorf("Error running calculate_halo_px: %v", err)
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
			return nil, nil, errors.New("Tile buffer exceeds module input_bytes_cap")
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
						return nil, nil, errors.New("Could not write tile to wasm memory")
					}
					tileX := x - halo
					tileY := y - halo
					if _, err := stage.tileFunc.Call(
						ctx,
						api.EncodeF32(float32(tileX)),
						api.EncodeF32(float32(tileY)),
					); err != nil {
						return nil, nil, fmt.Errorf("Error running tile_rgba32float_64x64: %w", wasmruntime.HumanizeExecutionError(ctx, err))
					}
					tileOutBytes, ok := stage.mem.Read(stage.inputPtr, uint32(len(tileBytes)))
					if !ok {
						return nil, nil, errors.New("Could not read tile from wasm memory")
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
						return nil, nil, errors.New("Could not write tile to wasm memory")
					}
					if _, err := stage.tileFunc.Call(
						ctx,
						api.EncodeF32(float32(x)),
						api.EncodeF32(float32(y)),
					); err != nil {
						return nil, nil, fmt.Errorf("Error running tile_rgba32float_64x64: %w", wasmruntime.HumanizeExecutionError(ctx, err))
					}
					tileOutBytes, ok := stage.mem.Read(stage.inputPtr, uint32(len(tileBytes)))
					if !ok {
						return nil, nil, errors.New("Could not read tile from wasm memory")
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
			return nil, instDurations, nil, errors.New("Wasm module could not be instantiated")
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

func decodeBMP(input []byte) (*image.RGBA, error) {
	if len(input) < 54 {
		return nil, errors.New("BMP input too small")
	}
	if input[0] != 'B' || input[1] != 'M' {
		return nil, errors.New("Input is not a BMP file")
	}

	dataOffset := int(binary.LittleEndian.Uint32(input[10:14]))
	dibSize := int(binary.LittleEndian.Uint32(input[14:18]))
	if dibSize < 40 {
		return nil, errors.New("Unsupported BMP DIB header")
	}
	width := int32(binary.LittleEndian.Uint32(input[18:22]))
	height := int32(binary.LittleEndian.Uint32(input[22:26]))
	planes := binary.LittleEndian.Uint16(input[26:28])
	bpp := binary.LittleEndian.Uint16(input[28:30])
	compression := binary.LittleEndian.Uint32(input[30:34])

	if width <= 0 || height == 0 {
		return nil, errors.New("Unsupported BMP dimensions")
	}
	if planes != 1 {
		return nil, errors.New("Unsupported BMP planes")
	}
	if compression != 0 {
		return nil, errors.New("Unsupported BMP compression")
	}
	if bpp != 24 && bpp != 32 {
		return nil, errors.New("Unsupported BMP bit depth")
	}

	topDown := false
	absHeight := int(height)
	if height < 0 {
		topDown = true
		absHeight = -absHeight
	}
	absWidth := int(width)
	if absWidth <= 0 || absHeight <= 0 {
		return nil, errors.New("Unsupported BMP dimensions")
	}

	bytesPerPixel := int(bpp / 8)
	rowStride := absWidth * bytesPerPixel
	if bpp == 24 {
		if rem := rowStride % 4; rem != 0 {
			rowStride += 4 - rem
		}
	}

	if dataOffset < 0 || dataOffset > len(input) {
		return nil, errors.New("Invalid BMP data offset")
	}
	if dataOffset+rowStride*absHeight > len(input) {
		return nil, errors.New("BMP pixel data out of range")
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
		return nil, errors.New("Invalid BMP image size")
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
	var maxMemoryBytes uint64
	var allowMemoryGrow bool
	fs := flag.NewFlagSet("image", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var imageVerbose bool
	fs.BoolVar(&imageVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&imageVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputImagePath, "i", "", "input image path")
	fs.StringVar(&outputImagePath, "o", "", "output image path")
	fs.IntVar(&timeoutMS, "timeout-ms", timeoutMS, "module execution timeout in milliseconds")
	fs.Uint64Var(&maxMemoryBytes, "max-memory", 0, "reject modules whose declared memory exceeds this byte cap")
	fs.BoolVar(&allowMemoryGrow, "allow-memory-grow", false, "allow memory.grow; requires --max-memory")
	if err := fs.Parse(normalizeImageArgs(args)); err != nil {
		gameOver("%s %v", usageImage, err)
	}
	opts.verbose = opts.verbose || imageVerbose
	if err := applyModulePolicyFlags(&opts, maxMemoryBytes, allowMemoryGrow); err != nil {
		gameOver("Invalid module policy: %v", err)
	}
	componentInvocations, parseErr := parseComponentInvocations(fs.Args(), "image")
	if parseErr != nil {
		gameOver("Invalid image module args: %v", parseErr)
	}
	if len(componentInvocations) == 0 || inputImagePath == "" || outputImagePath == "" {
		gameOver(usageImage)
	}
	if timeoutMS <= 0 {
		gameOver("Invalid timeout-ms: %d", timeoutMS)
	}

	moduleBodies := make([][]byte, len(componentInvocations))
	for i, spec := range componentInvocations {
		body, err := readModulePath(spec.Source, opts)
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
	defer r.Close(baseCtx)

	stages := make([]tileStage, len(moduleBodies))
	for i, body := range moduleBodies {
		mod, err := r.InstantiateWithConfig(execCtx, body, wazero.NewModuleConfig().WithName(fmt.Sprintf("image-%d", i)))
		if err != nil {
			gameOver("Wasm module could not be compiled")
		}
		if err := applyModuleUniforms(execCtx, mod, componentInvocations[i].UniformValues); err != nil {
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

func normalizeRunArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"-i":           {},
		"-o":           {},
		"--output":     {},
		"--timeout-ms": {},
		"--trace-with": {},
		"--max-memory": {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func normalizeBenchArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"-i":           {},
		"-r":           {},
		"--benchtime":  {},
		"--timeout-ms": {},
		"--max-memory": {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func normalizeImageArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"-i":           {},
		"-o":           {},
		"--timeout-ms": {},
		"--max-memory": {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func normalizeDevArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"--recipes":    {},
		"--components": {},
		"--mode":       {},
		"-p":           {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func normalizeRouteArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"--recipes":    {},
		"--components": {},
		"--mode":       {},
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

func buildDevETag(sourceDigest [32]byte, recipeDigests [][32]byte) string {
	if len(recipeDigests) == 0 {
		return fmt.Sprintf("\"%x\"", sourceDigest)
	}
	h := sha256.New()
	_, _ = h.Write(sourceDigest[:])
	for _, digest := range recipeDigests {
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

func routerResponseContentType(sourceMIME string, recipesApplied bool, output qinternal.Content, body []byte) string {
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
		return "", false, 0, false, errors.New("Wasm module could not be instantiated")
	}
	defer mod.Close(ctx)

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
	return outputType, hasOutputType, 0, false, nil
}

func formatOutputBytes(output qinternal.Content) ([]byte, error) {
	switch output.Encoding() {
	case qinternal.EncodingRawBytes, qinternal.EncodingUTF8, qinternal.EncodingBMP:
		return qinternal.AsRawBytes(output)
	default:
		return nil, errors.New("Unknown output encoding")
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

	return fmt.Errorf("unknown output encoding %v", result.Encoding())
}

// Image outputs already in the format the output path asks for are written
// as-is; re-encoding would only churn bytes (and Go's png encoder is used
// with NoCompression, inflating sizes).
func outputMatchesImagePath(result qinternal.Content, outputPath string) bool {
	contentType := normalizeIncomingContentType(qinternal.ContentTypeOf(result))
	switch strings.ToLower(filepath.Ext(outputPath)) {
	case ".png":
		return contentType == "image/png"
	case ".jpg", ".jpeg":
		return contentType == "image/jpeg"
	case ".bmp":
		return contentType == "image/bmp"
	default:
		return false
	}
}

func writeRunOutputToFile(result qinternal.Content, outputPath string) error {
	var data []byte

	if wantsImageReencode(outputPath) && !outputMatchesImagePath(result, outputPath) {
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

func getBMPDimensions(data []byte) (int, int, error) {
	if len(data) < 26 {
		return 0, 0, errors.New("BMP data too short")
	}
	if data[0] != 'B' || data[1] != 'M' {
		return 0, 0, errors.New("not a BMP file")
	}
	width := int(binary.LittleEndian.Uint32(data[18:22]))
	height := int(int32(binary.LittleEndian.Uint32(data[22:26])))
	if height < 0 {
		height = -height
	}
	return width, height, nil
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
	fmt.Fprintf(w, "<!doctype html><meta charset=\"utf-8\"><title>qip dev error</title><pre>%s\n%s</pre>", ts, html.EscapeString(err.Error()))
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
