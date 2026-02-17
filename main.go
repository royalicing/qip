package main

import (
	"bufio"
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
	_ "image/jpeg"
	"image/png"
	"io"
	"io/fs"
	"log"
	"math"
	"mime"
	"net/http"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"
	"unsafe"

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

type options struct {
	verbose bool
}

const usageMain = "Usage: qip <command> [args]\n\nCommands:\n  run   Run a chain of wasm modules on input\n  bench Compare one or more wasm modules for output parity and performance\n  image Run wasm filters on an input image\n  dev   Start a dev server for a content directory with optional recipes\n  help  Show command help"
const usageRun = "Usage: qip run [-v] [-i <input>] <wasm module URL or file>..."
const usageBench = "Usage: qip bench -i <input> [-r <benchmark runs> | --benchtime=<duration>] [--timeout-ms <ms>] <module1> [module2 ...]"
const usageImage = "Usage: qip image -i <input image path> -o <output image path> [-v] <wasm module URL or file>"
const usageDev = "Usage: qip dev <content_dir> [--recipes <recipes_dir>] [-p <port>] [-v|--verbose]"
const usageHelp = "Usage: qip help [command]"

const helpRun = "Usage: qip run [-v] [-i <input>] <wasm module URL or file>...\n\nModule contracts:\n  Run mode:\n    - Exports run(input_len), input_ptr, and input_utf8_cap or input_bytes_cap\n    - Exports output_ptr and output_utf8_cap or output_bytes_cap or output_i32_cap\n  Image mode:\n    - Exports tile_rgba_f32_64x64, input_ptr, input_bytes_cap\n    - Optional: uniform_set_width_and_height, calculate_halo_px\n\nComposition:\n  If a module exports tile_rgba_f32_64x64, qip run composes a contiguous image stage block.\n  Input to that block must be BMP bytes and the block outputs BMP bytes.\n  Run stages may follow and will receive BMP bytes.\n\nExample:\n  echo '<svg width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"#d52b1e\" /><rect x=\"13\" y=\"6\" width=\"6\" height=\"20\" fill=\"#ffffff\" /><rect x=\"6\" y=\"13\" width=\"20\" height=\"6\" fill=\"#ffffff\" /></svg>' | ./qip run examples/svg-rasterize.wasm examples/bmp-double.wasm examples/bmp-to-ico.wasm > out.ico"

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
		run(args[1:])
	} else if args[0] == "bench" {
		benchCmd(args[1:])
	} else if args[0] == "image" {
		imageCmd(args[1:])
	} else if args[0] == "dev" {
		devCmd(args[1:])
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
	case "image":
		fmt.Println(usageImage)
	case "dev":
		fmt.Println(usageDev)
	default:
		gameOver(usageHelp)
	}
}

func readModulePath(path string, opts options) ([]byte, error) {
	var body []byte

	if strings.HasPrefix(path, "https://") {
		resp, err := http.Get(path)
		if err != nil {
			return nil, fmt.Errorf("Error fetching URL: %v", err)
		}
		defer resp.Body.Close()

		body, err = io.ReadAll(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("Error reading response: %v", err)
		}
	} else {
		var err error
		body, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("Error reading file: %v", err)
		}
	}

	if opts.verbose {
		moduleDigest := sha256.Sum256(body)
		vlogf(opts, "module %s sha256: %x", path, moduleDigest)
	}

	return body, nil
}

func run(args []string) {
	opts := options{}
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var runVerbose bool
	var inputPath string
	fs.BoolVar(&runVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&runVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputPath, "i", "", "input file path")
	if err := fs.Parse(args); err != nil {
		gameOver("%s %v", usageRun, err)
	}
	opts.verbose = opts.verbose || runVerbose

	modules := fs.Args()
	if len(modules) < 1 {
		gameOver(usageRun)
	}

	ctx := context.Background()
	ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()

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

	chain, err := buildModuleChain(context.Background(), modules, opts)
	if err != nil {
		gameOver("%v", err)
	}
	defer chain.Close(context.Background())

	result, err := chain.run(ctx, input, 0)
	if err != nil {
		gameOver("%v", err)
	}

	if result.output.encoding == dataEncodingRaw {
		if _, err := os.Stdout.Write(result.output.bytes); err != nil {
			gameOver("Error writing raw output: %v", err)
		}
	} else if result.output.encoding == dataEncodingUTF8 {
		fmt.Printf("%s\n", result.output.bytes)
	} else if result.output.encoding == dataEncodingArrayI32 {
		if opts.verbose {
			fmt.Fprintln(os.Stderr, result.output.bytes)
		}

		count := len(result.output.bytes) / 4
		if count >= 1 {
			bufSize := count * 9
			writer := bufio.NewWriterSize(os.Stdout, bufSize)
			defer writer.Flush()
			for i := 0; i < count; i++ {
				v := binary.LittleEndian.Uint32(result.output.bytes[i*4:])
				if opts.verbose {
					vlogf(opts, "u32: %d", v)
				}
				if _, err := fmt.Fprintf(writer, "%08x\n", v); err != nil {
					gameOver("Error writing i32 output: %v", err)
				}
			}
		}
	}
}

type benchSample struct {
	total          time.Duration
	instantiation  time.Duration
	run            time.Duration
	memoryBytes    uint64
	inputCapBytes  uint64
	outputCapBytes uint64
}

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
	opts := options{}
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

	if err := fs.Parse(args); err != nil {
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
	runtime := wazero.NewRuntime(ctx)
	defer runtime.Close(ctx)

	moduleCount := len(modules)
	compiled := make([]wazero.CompiledModule, moduleCount)
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
		compiled[i] = cm
		defer compiled[i].Close(ctx)
	}

	perRunTimeout := time.Duration(timeoutMS) * time.Millisecond
	moduleInputCaps := make([]uint64, moduleCount)
	moduleOutputCaps := make([]uint64, moduleCount)
	firstSample, expected, err := runBenchSample(ctx, runtime, compiled[0], inputBytes, opts, "bench-0-check", perRunTimeout)
	if err != nil {
		gameOver("bench check failed for %s: %v", modules[0], err)
	}
	moduleInputCaps[0] = firstSample.inputCapBytes
	moduleOutputCaps[0] = firstSample.outputCapBytes
	for i := 1; i < moduleCount; i++ {
		sample, output, err := runBenchSample(ctx, runtime, compiled[i], inputBytes, opts, fmt.Sprintf("bench-%d-check", i), perRunTimeout)
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
	for i := 0; i < moduleCount; i++ {
		samples[i] = make([]benchSample, 0, benchRuns)
	}
	benchTimeTotals := make([]time.Duration, moduleCount)
	for i := 0; ; i++ {
		if benchtime == 0 && i >= benchRuns {
			break
		}
		startIndex := i % moduleCount
		for j := 0; j < moduleCount; j++ {
			moduleIndex := (startIndex + j) % moduleCount
			sample, output, err := runBenchSample(
				ctx,
				runtime,
				compiled[moduleIndex],
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
	for i := 0; i < moduleCount; i++ {
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

	for i := 0; i < moduleCount; i++ {
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
		ctxWithTimeout, cancelWithTimeout := context.WithTimeout(parent, timeout)
		ctx = ctxWithTimeout
		cancel = cancelWithTimeout
	}
	defer cancel()

	exec, err := executeModuleWithInput(ctx, runtime, compiled, inputBytes, opts, moduleName)
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
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

	mean := sum / float64(n)
	var variance float64
	for _, x := range ns {
		delta := x - mean
		variance += delta * delta
	}
	variance /= float64(n)

	p95Index := int(math.Ceil(0.95*float64(n))) - 1
	if p95Index < 0 {
		p95Index = 0
	}
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
		"output length differs (expected len=%d sha256=%x, actual len=%d sha256=%x)",
		len(expected.bytes),
		expSum,
		len(actual.bytes),
		actSum,
	)
}

func firstDiffIndex(a, b []byte) int {
	limit := len(a)
	if len(b) < limit {
		limit = len(b)
	}
	for i := 0; i < limit; i++ {
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
		return tileStage{}, errors.New("Wasm module must export tile_rgba_f32_64x64")
	}
	uniformFunc := mod.ExportedFunction("uniform_set_width_and_height")
	haloFunc := mod.ExportedFunction("calculate_halo_px")
	mem := mod.Memory()
	inputPtrValue, ok := getExportedValue(ctx, mod, "input_ptr")
	if !ok {
		return tileStage{}, errors.New("Wasm module must export input_ptr as global or function")
	}
	inputCap, ok := getExportedValue(ctx, mod, "input_bytes_cap")
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
		for y := 0; y < height; y++ {
			srcRow := y * stride
			dstRow := y * width * 4
			for x := 0; x < width; x++ {
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
					for row := 0; row < tileSpan; row++ {
						srcY := y + row - halo
						if srcY < 0 {
							srcY = 0
						} else if srcY >= height {
							srcY = height - 1
						}
						srcRow := srcY * width * 4
						dstRow := row * tileSpan * 4
						for col := 0; col < tileSpan; col++ {
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
						return nil, nil, fmt.Errorf("Error running tile_rgba_f32_64x64: %v", err)
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
		for y := 0; y < height; y++ {
			srcRow := y * width * 4
			dstRow := y * outStride
			for x := 0; x < width; x++ {
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
					if !stage.mem.Write(stage.inputPtr, tileBytes) {
						return nil, nil, errors.New("Could not write tile to wasm memory")
					}
					if _, err := stage.tileFunc.Call(
						ctx,
						api.EncodeF32(float32(x)),
						api.EncodeF32(float32(y)),
					); err != nil {
						return nil, nil, fmt.Errorf("Error running tile_rgba_f32_64x64: %v", err)
					}
					tileOutBytes, ok := stage.mem.Read(stage.inputPtr, uint32(len(tileBytes)))
					if !ok {
						return nil, nil, errors.New("Could not read tile from wasm memory")
					}
					copy(tileBytes, tileOutBytes)
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
		for x := 0; x < absWidth; x++ {
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

	for y := 0; y < height; y++ {
		srcY := height - 1 - y
		for x := 0; x < width; x++ {
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
	opts := options{}
	var inputImagePath string
	var outputImagePath string
	fs := flag.NewFlagSet("image", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var imageVerbose bool
	fs.BoolVar(&imageVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&imageVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputImagePath, "i", "", "input image path")
	fs.StringVar(&outputImagePath, "o", "", "output image path")
	if err := fs.Parse(args); err != nil {
		gameOver("%s %v", usageImage, err)
	}
	opts.verbose = opts.verbose || imageVerbose
	modules := fs.Args()
	if len(modules) == 0 || inputImagePath == "" || outputImagePath == "" {
		gameOver(usageImage)
	}

	moduleBodies := make([][]byte, len(modules))
	for i, modulePath := range modules {
		body, err := readModulePath(modulePath, opts)
		if err != nil {
			gameOver("%v", err)
		}
		moduleBodies[i] = body
	}

	ctx := context.Background()
	ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()

	inputImageBytes, err := os.ReadFile(inputImagePath)
	if err != nil {
		gameOver("Error reading image file: %v", err)
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

	r := wazero.NewRuntime(ctx)
	defer r.Close(ctx)

	stages := make([]tileStage, len(moduleBodies))
	for i, body := range moduleBodies {
		mod, err := r.InstantiateWithConfig(ctx, body, wazero.NewModuleConfig())
		if err != nil {
			gameOver("Wasm module could not be compiled")
		}
		stage, err := loadTileStage(ctx, mod)
		if err != nil {
			gameOver("%v", err)
		}
		stages[i] = stage
	}
	defer closeTileStages(ctx, stages)
	outputRGBA, _, err := runTileStages(ctx, stages, inputRGBA)
	if err != nil {
		gameOver("%v", err)
	}

	outFile, err := os.Create(outputImagePath)
	if err != nil {
		gameOver("Error creating output image file: %v", err)
	}
	defer outFile.Close()
	encoder := png.Encoder{CompressionLevel: png.NoCompression}
	if err := encoder.Encode(outFile, outputRGBA); err != nil {
		gameOver("Error writing output image: %v", err)
	}
}

// getExportedValue tries to get a value from either a global or a function
func getExportedValue(ctx context.Context, mod api.Module, name string) (uint64, bool) {
	// Try global first
	if global := mod.ExportedGlobal(name); global != nil {
		return global.Get(), true
	}

	// Try function if global doesn't exist
	if fn := mod.ExportedFunction(name); fn != nil {
		result, err := fn.Call(ctx)
		if err == nil && len(result) > 0 {
			return result[0], true
		}
	}

	return 0, false
}

type moduleExecutionResult struct {
	output         contentData
	instantiation  time.Duration
	run            time.Duration
	total          time.Duration
	memoryBytes    uint64
	inputCapBytes  uint64
	outputCapBytes uint64
}

func runModuleWithInput(ctx context.Context, runtime wazero.Runtime, compiled wazero.CompiledModule, inputBytes []byte, opts options, moduleName string) (output contentData, instantiation time.Duration, returnErr error) {
	exec, err := executeModuleWithInput(ctx, runtime, compiled, inputBytes, opts, moduleName)
	if err != nil {
		return contentData{}, 0, err
	}
	return exec.output, exec.instantiation, nil
}

func executeModuleWithInput(ctx context.Context, runtime wazero.Runtime, compiled wazero.CompiledModule, inputBytes []byte, opts options, moduleName string) (exec moduleExecutionResult, returnErr error) {
	totalStart := time.Now()
	defer func() {
		exec.total = time.Since(totalStart)
	}()

	instStart := time.Now()
	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName(moduleName))
	if err != nil {
		returnErr = errors.New("Wasm module could not be instantiated")
		return
	}
	defer mod.Close(ctx)
	exec.instantiation = time.Since(instStart)

	var input contentData
	// Get input_ptr and input_cap (required)
	inputPtr, ok := getExportedValue(ctx, mod, "input_ptr")
	if !ok {
		returnErr = errors.New("Wasm module must export input_ptr as global or function")
		return
	}

	inputCap, ok := getExportedValue(ctx, mod, "input_utf8_cap")
	if ok {
		input.encoding = dataEncodingUTF8
	} else if cap, ok := getExportedValue(ctx, mod, "input_bytes_cap"); ok {
		inputCap = cap
		input.encoding = dataEncodingRaw
	} else {
		returnErr = errors.New("Wasm module must export input_utf8_cap or input_bytes_cap as global or function")
		return
	}
	exec.inputCapBytes = inputCap

	var outputPtr, outputCap uint32
	if ptr, ok := getExportedValue(ctx, mod, "output_ptr"); ok {
		outputPtr = uint32(ptr)

		if cap, ok := getExportedValue(ctx, mod, "output_utf8_cap"); ok {
			outputCap = uint32(cap)
			exec.output.encoding = dataEncodingUTF8
		} else if cap, ok := getExportedValue(ctx, mod, "output_i32_cap"); ok {
			outputCap = uint32(cap)
			exec.output.encoding = dataEncodingArrayI32
		} else if cap, ok := getExportedValue(ctx, mod, "output_bytes_cap"); ok {
			outputCap = uint32(cap)
			exec.output.encoding = dataEncodingRaw
		} else {
			returnErr = errors.New("Wasm module must export output_utf8_cap or output_i32_cap or output_bytes_cap function")
			return
		}
	}
	exec.outputCapBytes = uint64(outputCap)

	runFunc := mod.ExportedFunction("run")

	var inputSize = uint64(len(inputBytes))
	if inputSize > inputCap {
		returnErr = errors.New("Input is too large")
		return
	}

	mem := mod.Memory()
	if !mem.Write(uint32(inputPtr), inputBytes) {
		returnErr = errors.New("Could not write input")
		return
	}

	runStart := time.Now()
	runResult, returnErr := runFunc.Call(ctx, inputSize)
	exec.run = time.Since(runStart)
	if returnErr != nil {
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
			returnErr = errors.New("Module returned more bytes than its stated capacity")
			return
		}
		outputBytes, ok := mem.Read(outputPtr, uint32(outputCountBytes))
		if !ok {
			returnErr = errors.New("Could not read output")
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

type devContentRoute struct {
	filePath   string
	sourceMIME string
}

type recipeCandidate struct {
	path     string
	filename string
	order    int
	digest   [32]byte
}

func devCmd(args []string) {
	opts := options{}
	var recipesRoot string
	port := 4000
	fs := flag.NewFlagSet("dev", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var devVerbose bool
	fs.BoolVar(&devVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&devVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe modules root directory")
	fs.IntVar(&port, "p", 4000, "port")
	if err := fs.Parse(normalizeDevArgs(args)); err != nil {
		gameOver("%s %v", usageDev, err)
	}

	opts.verbose = devVerbose
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

	contentRoutes, err := buildDevContentRoutes(contentRoot)
	if err != nil {
		gameOver("%v", err)
	}

	recipeChains, recipeDigests, err := loadRecipeChains(context.Background(), recipesRoot, opts)
	if err != nil {
		gameOver("%v", err)
	}
	defer closeModuleChains(context.Background(), recipeChains)

	log.Printf("dev: indexed %d request paths from %s", len(contentRoutes), contentRoot)
	if recipesRoot != "" {
		log.Printf("dev: loaded %d recipe mime chains from %s", len(recipeChains), recipesRoot)
	}

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	mux := http.NewServeMux()
	var requestID uint64
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		reqID := atomic.AddUint64(&requestID, 1)
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			emptyDurations := []time.Duration{}
			emptyInst := []time.Duration{}
			w.WriteHeader(http.StatusMethodNotAllowed)
			log.Printf("dev: %s %s %s", r.Method, r.URL.Path, formatDurationParts(time.Since(start), emptyDurations, emptyInst))
			return
		}

		route, ok := resolveDevContentRoute(contentRoutes, r.URL.Path)
		if !ok {
			emptyDurations := []time.Duration{}
			emptyInst := []time.Duration{}
			http.NotFound(w, r)
			log.Printf("dev: %s %s status=404 %s", r.Method, r.URL.Path, formatDurationParts(time.Since(start), emptyDurations, emptyInst))
			return
		}

		inputBytes, err := os.ReadFile(route.filePath)
		if err != nil {
			emptyDurations := []time.Duration{}
			emptyInst := []time.Duration{}
			writeDevError(w, err)
			log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), emptyDurations, emptyInst))
			return
		}
		sourceDigest := sha256.Sum256(inputBytes)

		result := chainResult{
			output: contentData{bytes: inputBytes, encoding: dataEncodingRaw},
			metrics: chainMetrics{
				moduleDurations:        []time.Duration{},
				instantiationDurations: []time.Duration{},
			},
		}
		_, hasRecipes := recipeChains[route.sourceMIME]
		if hasRecipes {
			chain := recipeChains[route.sourceMIME]
			ctx := context.Background()
			ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
			defer cancel()
			result, err = chain.run(ctx, inputBytes, reqID)
			if err != nil {
				writeDevError(w, err)
				log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
				return
			}
		}

		body, err := formatOutputBytes(result.output)
		if err != nil {
			writeDevError(w, err)
			log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
			return
		}

		etag := buildDevETag(sourceDigest, recipeDigests[route.sourceMIME])
		if etag != "" {
			w.Header().Set("ETag", etag)
			if r.Header.Get("If-None-Match") == etag {
				w.WriteHeader(http.StatusNotModified)
				log.Printf("dev: %s %s status=304 %s", r.Method, r.URL.Path, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
				return
			}
		}
		contentType := devResponseContentType(route.sourceMIME, hasRecipes, result.output, body)
		w.Header().Set("Content-Type", contentType)
		w.WriteHeader(http.StatusOK)
		if r.Method != http.MethodHead {
			if _, err := w.Write(body); err != nil {
				log.Printf("dev: %s %s write_error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
				return
			}
		}
		log.Printf("dev: %s %s status=200 %s", r.Method, r.URL.Path, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
	})

	server := &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		<-signalCtx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("dev: listening on http://%s", addr)

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		gameOver("dev server error: %v", err)
	}
}

func normalizeDevArgs(args []string) []string {
	if len(args) == 0 {
		return args
	}
	first := args[0]
	if strings.HasPrefix(first, "-") {
		return args
	}

	normalized := make([]string, 0, len(args))
	normalized = append(normalized, args[1:]...)
	normalized = append(normalized, first)
	return normalized
}

func buildDevContentRoutes(contentRoot string) (map[string]devContentRoute, error) {
	files := make([]struct {
		rel  string
		full string
	}, 0, 32)
	err := filepath.WalkDir(contentRoot, func(fullPath string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("content entry %q must be a regular file", fullPath)
		}
		relPath, err := filepath.Rel(contentRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if !utf8.ValidString(relPath) {
			return fmt.Errorf("content path %q must be valid UTF-8", relPath)
		}
		if strings.Contains(relPath, "\\") {
			return fmt.Errorf("content path %q must not contain backslash", relPath)
		}
		if strings.HasPrefix(relPath, "/") {
			return fmt.Errorf("content path %q must not start with /", relPath)
		}
		cleanRel := path.Clean(relPath)
		if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
			return fmt.Errorf("content path %q is not canonical", relPath)
		}
		files = append(files, struct {
			rel  string
			full string
		}{rel: relPath, full: fullPath})
		return nil
	})
	if err != nil {
		return nil, err
	}

	sort.Slice(files, func(i, j int) bool {
		return files[i].rel < files[j].rel
	})

	routes := make(map[string]devContentRoute, len(files))
	for _, entry := range files {
		aliases := contentRequestPaths(entry.rel)
		route := devContentRoute{
			filePath:   entry.full,
			sourceMIME: detectSourceMIME(entry.rel),
		}
		for _, requestPath := range aliases {
			if prev, exists := routes[requestPath]; exists && prev.filePath != route.filePath {
				return nil, fmt.Errorf("duplicate route path %q for %q and %q", requestPath, prev.filePath, route.filePath)
			}
			routes[requestPath] = route
		}
	}

	return routes, nil
}

func contentRequestPaths(relPath string) []string {
	out := make([]string, 0, 4)
	appendUnique := func(value string) {
		for _, existing := range out {
			if existing == value {
				return
			}
		}
		out = append(out, value)
	}

	appendUnique("/" + relPath)
	ext := path.Ext(relPath)
	lowerExt := strings.ToLower(ext)
	if lowerExt == ".html" || lowerExt == ".md" || lowerExt == ".markdown" {
		base := path.Base(relPath)
		if strings.EqualFold(base, "index"+ext) {
			dir := path.Dir(relPath)
			if dir == "." {
				appendUnique("/")
			} else {
				appendUnique("/" + dir)
				appendUnique("/" + dir + "/")
			}
		} else {
			appendUnique("/" + strings.TrimSuffix(relPath, ext))
		}
	}
	return out
}

func detectSourceMIME(relPath string) string {
	ext := strings.ToLower(path.Ext(relPath))
	switch ext {
	case ".md", ".markdown":
		return "text/markdown"
	}

	mimeType := mime.TypeByExtension(ext)
	if mimeType == "" {
		return "application/octet-stream"
	}
	if cut := strings.IndexByte(mimeType, ';'); cut != -1 {
		mimeType = strings.TrimSpace(mimeType[:cut])
	}
	if mimeType == "" {
		return "application/octet-stream"
	}
	return mimeType
}

func resolveDevContentRoute(routes map[string]devContentRoute, requestPath string) (devContentRoute, bool) {
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}

	candidates := []string{requestPath}
	clean := path.Clean(requestPath)
	if clean == "." {
		clean = "/"
	}
	if !strings.HasPrefix(clean, "/") {
		clean = "/" + clean
	}
	if clean != requestPath {
		candidates = append(candidates, clean)
	}
	if requestPath != "/" {
		if strings.HasSuffix(requestPath, "/") {
			candidates = append(candidates, strings.TrimSuffix(requestPath, "/"))
		} else {
			candidates = append(candidates, requestPath+"/")
		}
	}

	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if _, ok := seen[candidate]; ok {
			continue
		}
		seen[candidate] = struct{}{}
		if route, ok := routes[candidate]; ok {
			return route, true
		}
	}
	return devContentRoute{}, false
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

func loadRecipeChains(ctx context.Context, recipesRoot string, opts options) (map[string]*moduleChain, map[string][][32]byte, error) {
	chains := make(map[string]*moduleChain)
	digestsByMIME := make(map[string][][32]byte)
	if recipesRoot == "" {
		return chains, digestsByMIME, nil
	}

	candidatesByMIME := make(map[string][]recipeCandidate)
	err := filepath.WalkDir(recipesRoot, func(fullPath string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("recipe entry %q must be a regular file", fullPath)
		}

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
		chain, err := buildModuleChain(ctx, modulePaths, opts)
		if err != nil {
			closeModuleChains(ctx, chains)
			return nil, nil, err
		}
		chains[mimeType] = chain
		digestsByMIME[mimeType] = digests
	}

	return chains, digestsByMIME, nil
}

func closeModuleChains(ctx context.Context, chains map[string]*moduleChain) {
	for _, chain := range chains {
		chain.Close(ctx)
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

func devResponseContentType(sourceMIME string, recipesApplied bool, output contentData, body []byte) string {
	if recipesApplied && sourceMIME == "text/markdown" {
		return "text/html; charset=utf-8"
	}
	if output.encoding == dataEncodingRaw {
		if isICOBytes(body) {
			return "image/x-icon"
		}
		if isBMPBytes(body) {
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

type chainMetrics struct {
	moduleDurations        []time.Duration
	instantiationDurations []time.Duration
}

type chainResult struct {
	output  contentData
	metrics chainMetrics
}

type stageKind uint8

const (
	stageKindRun stageKind = iota
	stageKindTile
)

type moduleStage struct {
	compiled wazero.CompiledModule
	kind     stageKind
}

type moduleChain struct {
	runtime          wazero.Runtime
	stages           []moduleStage
	opts             options
	compileDurations []time.Duration
}

func buildModuleChain(ctx context.Context, modules []string, opts options) (*moduleChain, error) {
	if len(modules) == 0 {
		return &moduleChain{opts: opts}, nil
	}

	runtime := wazero.NewRuntime(ctx)
	stages := make([]moduleStage, len(modules))
	compileDurations := make([]time.Duration, len(modules))

	for i, modulePath := range modules {
		body, err := readModulePath(modulePath, opts)
		if err != nil {
			_ = runtime.Close(ctx)
			return nil, err
		}
		start := time.Now()
		cm, err := runtime.CompileModule(ctx, body)
		compileDurations[i] = time.Since(start)
		if err != nil {
			_ = runtime.Close(ctx)
			return nil, errors.New("Wasm module could not be compiled")
		}
		kind := stageKindRun
		if _, ok := cm.ExportedFunctions()["tile_rgba_f32_64x64"]; ok {
			kind = stageKindTile
		}
		stages[i] = moduleStage{
			compiled: cm,
			kind:     kind,
		}
		if opts.verbose {
			vlogf(opts, "compiled module[%d] in %dms", i, compileDurations[i].Milliseconds())
		}
	}

	seenTile := false
	seenRunAfterTile := false
	for i, stage := range stages {
		if stage.kind == stageKindTile {
			if seenRunAfterTile {
				_ = runtime.Close(ctx)
				return nil, fmt.Errorf("Image stages must be contiguous to compose (module %d)", i)
			}
			seenTile = true
			continue
		}
		if seenTile {
			seenRunAfterTile = true
		}
	}

	return &moduleChain{
		runtime:          runtime,
		stages:           stages,
		opts:             opts,
		compileDurations: compileDurations,
	}, nil
}

func (chain *moduleChain) Close(ctx context.Context) {
	for _, stage := range chain.stages {
		_ = stage.compiled.Close(ctx)
	}
	if chain.runtime != nil {
		_ = chain.runtime.Close(ctx)
	}
}

func (chain *moduleChain) run(ctx context.Context, input []byte, requestID uint64) (chainResult, error) {
	if len(chain.stages) == 0 {
		return chainResult{
			output: contentData{bytes: input, encoding: dataEncodingRaw},
			metrics: chainMetrics{
				moduleDurations:        []time.Duration{},
				instantiationDurations: []time.Duration{},
			},
		}, nil
	}

	moduleDurations := make([]time.Duration, len(chain.stages))
	instantiationDurations := make([]time.Duration, len(chain.stages))
	var output contentData
	cur := input

	tileStart := -1
	tileEnd := -1
	for i, stage := range chain.stages {
		if stage.kind == stageKindTile {
			if tileStart == -1 {
				tileStart = i
			}
			tileEnd = i
		}
	}

	runRunStages := func(start, end int, inputBytes []byte) (contentData, []byte, error) {
		curBytes := inputBytes
		var localOutput contentData
		for i := start; i < end; i++ {
			stage := chain.stages[i]
			moduleName := fmt.Sprintf("req-%d-%d", requestID, i)
			runStart := time.Now()
			nextOutput, instDur, err := runModuleWithInput(ctx, chain.runtime, stage.compiled, curBytes, chain.opts, moduleName)
			moduleDurations[i] = time.Since(runStart)
			instantiationDurations[i] = instDur
			if err != nil {
				return localOutput, curBytes, err
			}
			localOutput = nextOutput
			curBytes = nextOutput.bytes
		}
		return localOutput, curBytes, nil
	}

	if tileStart == -1 {
		out, curBytes, err := runRunStages(0, len(chain.stages), cur)
		if err != nil {
			return chainResult{
				output: out,
				metrics: chainMetrics{
					moduleDurations:        moduleDurations,
					instantiationDurations: instantiationDurations,
				},
			}, err
		}
		output = out
		cur = curBytes
	} else {
		if tileStart > 0 {
			out, curBytes, err := runRunStages(0, tileStart, cur)
			if err != nil {
				return chainResult{
					output: out,
					metrics: chainMetrics{
						moduleDurations:        moduleDurations,
						instantiationDurations: instantiationDurations,
					},
				}, err
			}
			output = out
			cur = curBytes
			if output.encoding != dataEncodingRaw {
				return chainResult{
					output: output,
					metrics: chainMetrics{
						moduleDurations:        moduleDurations,
						instantiationDurations: instantiationDurations,
					},
				}, errors.New("Image stage requires raw BMP bytes as input")
			}
		} else {
			output = contentData{bytes: cur, encoding: dataEncodingRaw}
		}

		inputRGBA, err := decodeBMP(cur)
		if err != nil {
			return chainResult{
				output: output,
				metrics: chainMetrics{
					moduleDurations:        moduleDurations,
					instantiationDurations: instantiationDurations,
				},
			}, err
		}
		tileCompiled := make([]wazero.CompiledModule, tileEnd-tileStart+1)
		for i := tileStart; i <= tileEnd; i++ {
			tileCompiled[i-tileStart] = chain.stages[i].compiled
		}
		moduleNamePrefix := fmt.Sprintf("req-%d", requestID)
		tileOutput, instDurs, stageDurs, err := runTileStagesCompiled(ctx, chain.runtime, tileCompiled, inputRGBA, moduleNamePrefix, tileStart)
		for i := range instDurs {
			instantiationDurations[tileStart+i] = instDurs[i]
		}
		for i := range stageDurs {
			moduleDurations[tileStart+i] = stageDurs[i]
		}
		if err != nil {
			return chainResult{
				output: output,
				metrics: chainMetrics{
					moduleDurations:        moduleDurations,
					instantiationDurations: instantiationDurations,
				},
			}, err
		}
		bmpBytes, err := encodeBMP(tileOutput)
		if err != nil {
			return chainResult{
				output: output,
				metrics: chainMetrics{
					moduleDurations:        moduleDurations,
					instantiationDurations: instantiationDurations,
				},
			}, err
		}
		output = contentData{bytes: bmpBytes, encoding: dataEncodingRaw}
		cur = bmpBytes

		if tileEnd+1 < len(chain.stages) {
			out, curBytes, err := runRunStages(tileEnd+1, len(chain.stages), cur)
			if err != nil {
				return chainResult{
					output: out,
					metrics: chainMetrics{
						moduleDurations:        moduleDurations,
						instantiationDurations: instantiationDurations,
					},
				}, err
			}
			output = out
			cur = curBytes
		}
	}

	return chainResult{
		output: output,
		metrics: chainMetrics{
			moduleDurations:        moduleDurations,
			instantiationDurations: instantiationDurations,
		},
	}, nil
}

func formatOutputBytes(output contentData) ([]byte, error) {
	switch output.encoding {
	case dataEncodingRaw, dataEncodingUTF8:
		return output.bytes, nil
	case dataEncodingArrayI32:
		count := len(output.bytes) / 4
		var buf bytes.Buffer
		buf.Grow(count * 9)
		for i := 0; i < count; i++ {
			v := binary.LittleEndian.Uint32(output.bytes[i*4:])
			fmt.Fprintf(&buf, "%08x\n", v)
		}
		return buf.Bytes(), nil
	default:
		return nil, errors.New("Unknown output encoding")
	}
}

func isBMPBytes(data []byte) bool {
	if len(data) < 18 {
		return false
	}
	if data[0] != 'B' || data[1] != 'M' {
		return false
	}

	fileSize := binary.LittleEndian.Uint32(data[2:6])
	if fileSize != 0 && fileSize > uint32(len(data)) {
		return false
	}

	pixelOffset := binary.LittleEndian.Uint32(data[10:14])
	if pixelOffset < 14 || pixelOffset > uint32(len(data)) {
		return false
	}

	dibSize := binary.LittleEndian.Uint32(data[14:18])
	if dibSize < 12 {
		return false
	}
	if 14+dibSize > uint32(len(data)) {
		return false
	}

	return true
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
