package main

import (
	"bufio"
	"bytes"
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
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
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

type contentData struct {
	bytes    []byte
	encoding dataEncoding
}

type options struct {
	verbose bool
}

const usageRun = "Usage: qip <wasm module URL or file>...\n       qip run [-v] <wasm module URL or file>..."
const usageImage = "Usage: qip image -i <input image path> -o <output image path> [-v] <wasm module URL or file>"
const usageDev = "Usage: qip dev -i <input> [-p <port>] [-v|--verbose] [-- <module1> <module2> ...]"

func main() {
	args := os.Args[1:]

	if len(args) == 0 {
		gameOver(usageRun)
	}

	if args[0] == "-v" || args[0] == "--verbose" {
		gameOver(usageRun)
	}

	if args[0] == "run" {
		run(args[1:])
	} else if args[0] == "image" {
		imageCmd(args[1:])
	} else if args[0] == "dev" {
		devCmd(args[1:])
	} else {
		run(args)
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
	fs.BoolVar(&runVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&runVerbose, "verbose", false, "enable verbose logging")
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

	chain, err := buildModuleChain(modules, opts)
	if err != nil {
		gameOver("%v", err)
	}

	durations := make([]time.Duration, 0)
	output, err := chain(ctx, input, durations)
	if err != nil {
		gameOver("%v", err)
	}

	if output.encoding == dataEncodingRaw {
		if _, err := os.Stdout.Write(output.bytes); err != nil {
			gameOver("Error writing raw output: %v", err)
		}
	} else if output.encoding == dataEncodingUTF8 {
		fmt.Printf("%s\n", output.bytes)
	} else if output.encoding == dataEncodingArrayI32 {
		if opts.verbose {
			fmt.Fprintln(os.Stderr, output.bytes)
		}

		count := len(output.bytes) / 4
		if count >= 1 {
			bufSize := count * 9
			writer := bufio.NewWriterSize(os.Stdout, bufSize)
			defer writer.Flush()
			for i := 0; i < count; i++ {
				v := binary.LittleEndian.Uint32(output.bytes[i*4:])
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
	bounds := inputRGBA.Bounds()
	outputRGBA := image.NewRGBA(bounds)

	start := time.Now()
	defer func() {
		if opts.verbose {
			vlogf(opts, "command took %dms", time.Since(start).Milliseconds())
		}
	}()

	r := wazero.NewRuntime(ctx)
	defer r.Close(ctx)

	const tileSize = 64
	type tileStage struct {
		mem         api.Memory
		tileFunc    api.Function
		inputPtr    uint32
		uniformFunc api.Function
		haloFunc    api.Function
		inputCap    uint64
		haloPx      int
		tileSpan    int
	}
	stages := make([]tileStage, len(moduleBodies))
	for i, body := range moduleBodies {
		mod, err := r.InstantiateWithConfig(ctx, body, wazero.NewModuleConfig())
		if err != nil {
			gameOver("Wasm module could not be compiled")
		}
		tileFunc := mod.ExportedFunction("tile_rgba_f32_64x64")
		if tileFunc == nil {
			gameOver("Wasm module must export tile_rgba_f32_64x64")
		}
		uniformFunc := mod.ExportedFunction("uniform_set_width_and_height")
		haloFunc := mod.ExportedFunction("calculate_halo_px")
		mem := mod.Memory()
		inputPtrValue, ok := getExportedValue(ctx, mod, "input_ptr")
		if !ok {
			gameOver("Wasm module must export input_ptr as global or function")
		}
		inputPtr := uint32(inputPtrValue)
		inputCap, ok := getExportedValue(ctx, mod, "input_bytes_cap")
		if !ok {
			gameOver("Wasm module must export input_bytes_cap as global or function")
		}
		stages[i] = tileStage{
			mem:         mem,
			tileFunc:    tileFunc,
			inputPtr:    inputPtr,
			uniformFunc: uniformFunc,
			haloFunc:    haloFunc,
			inputCap:    inputCap,
		}
	}
	width := bounds.Dx()
	height := bounds.Dy()
	for i := range stages {
		stage := &stages[i]
		if stage.uniformFunc != nil {
			if _, err := stage.uniformFunc.Call(
				ctx,
				api.EncodeF32(float32(width)),
				api.EncodeF32(float32(height)),
			); err != nil {
				gameOver("Error running uniform_set_width_and_height: %v", err)
			}
		}
		if stage.haloFunc != nil {
			values, err := stage.haloFunc.Call(ctx)
			if err != nil {
				gameOver("Error running calculate_halo_px: %v", err)
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
			gameOver("Tile buffer exceeds module input_bytes_cap")
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
						gameOver("Could not write tile to wasm memory")
					}
					tileX := x - halo
					tileY := y - halo
					if _, err := stage.tileFunc.Call(
						ctx,
						api.EncodeF32(float32(tileX)),
						api.EncodeF32(float32(tileY)),
					); err != nil {
						gameOver("Error running tile_rgba_f32_64x64: %v", err)
					}
					tileOutBytes, ok := stage.mem.Read(stage.inputPtr, uint32(len(tileBytes)))
					if !ok {
						gameOver("Could not read tile from wasm memory")
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
				for _, stage := range stages {
					if !stage.mem.Write(stage.inputPtr, tileBytes) {
						gameOver("Could not write tile to wasm memory")
					}
					if _, err := stage.tileFunc.Call(
						ctx,
						api.EncodeF32(float32(x)),
						api.EncodeF32(float32(y)),
					); err != nil {
						gameOver("Error running tile_rgba_f32_64x64: %v", err)
					}
					tileOutBytes, ok := stage.mem.Read(stage.inputPtr, uint32(len(tileBytes)))
					if !ok {
						gameOver("Could not read tile from wasm memory")
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

func runModuleWithInput(ctx context.Context, modBytes []byte, inputBytes []byte, opts options) (output contentData, returnErr error) {
	r := wazero.NewRuntime(ctx)
	defer r.Close(ctx)

	mod, err := r.InstantiateWithConfig(ctx, modBytes, wazero.NewModuleConfig())
	if err != nil {
		returnErr = errors.New("Wasm module could not be compiled")
		return
	}

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

	var outputPtr, outputCap uint32
	if ptr, ok := getExportedValue(ctx, mod, "output_ptr"); ok {
		outputPtr = uint32(ptr)

		if cap, ok := getExportedValue(ctx, mod, "output_utf8_cap"); ok {
			outputCap = uint32(cap)
			output.encoding = dataEncodingUTF8
		} else if cap, ok := getExportedValue(ctx, mod, "output_i32_cap"); ok {
			outputCap = uint32(cap)
			output.encoding = dataEncodingArrayI32
		} else if cap, ok := getExportedValue(ctx, mod, "output_bytes_cap"); ok {
			outputCap = uint32(cap)
			output.encoding = dataEncodingRaw
		} else {
			returnErr = errors.New("Wasm module must export output_utf8_cap or output_i32_cap or output_bytes_cap function")
			return
		}
	}

	runFunc := mod.ExportedFunction("run")

	// inputPtrResult, err := mod.ExportedFunction("input_ptr").Call(ctx)
	// if err != nil {
	// 	gameOver("Wasm module must export an input_ptr() function")
	// }

	var inputSize = uint64(len(inputBytes))
	if inputSize > inputCap {
		returnErr = errors.New("Input is too large")
		return
	}

	if !mod.Memory().Write(uint32(inputPtr), inputBytes) {
		returnErr = errors.New("Could not write input")
		return
	}

	runResult, returnErr := runFunc.Call(ctx, inputSize)
	if returnErr != nil {
		return
	}

	outputCount := uint32(runResult[0])

	var outputItemFactor uint32
	if output.encoding == dataEncodingArrayI32 {
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
		outputBytes, _ := mod.Memory().Read(outputPtr, uint32(outputCountBytes))
		output.bytes = outputBytes
		if opts.verbose && len(output.bytes) > 0 {
			sum := sha256.Sum256(output.bytes)
			vlogf(opts, "output sha256: %x", sum)
		}
	} else {
		fmt.Printf("Ran: %d\n", runResult[0])
	}

	// Detect if outputBytes are wasm module by checking for magic number
	// if len(outputBytes) >= 4 && outputBytes[0] == 0x00 && outputBytes[1] == 0x61 && outputBytes[2] == 0x73 && outputBytes[3] == 0x6D {
	// }

	return output, nil
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

func devCmd(args []string) {
	opts := options{}
	var inputPath string
	port := 4000
	fs := flag.NewFlagSet("dev", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var devVerbose bool
	fs.BoolVar(&devVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&devVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&inputPath, "i", "", "input file path")
	fs.IntVar(&port, "p", 4000, "port")

	separator := -1
	for i, arg := range args {
		if arg == "--" {
			separator = i
			break
		}
	}
	var modules []string
	if separator == -1 {
		if err := fs.Parse(args); err != nil {
			gameOver("%s %v", usageDev, err)
		}
		modules = fs.Args()
	} else {
		if err := fs.Parse(args[:separator]); err != nil {
			gameOver("%s %v", usageDev, err)
		}
		if len(fs.Args()) > 0 {
			gameOver(usageDev)
		}
		modules = args[separator+1:]
	}

	opts.verbose = devVerbose
	if inputPath == "" {
		gameOver(usageDev)
	}
	if port <= 0 || port > 65535 {
		gameOver("Invalid port: %d", port)
	}

	chain, err := buildModuleChain(modules, opts)
	if err != nil {
		gameOver("%v", err)
	}

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			log.Printf("dev: %s %s %s", r.Method, r.URL.Path, formatDurationParts(time.Since(start), nil))
			return
		}

		inputBytes, err := os.ReadFile(inputPath)
		if err != nil {
			writeDevError(w, err)
			log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), nil))
			return
		}

		ctx := context.Background()
		ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
		defer cancel()

		durations := make([]time.Duration, len(modules))
		output, err := chain(ctx, inputBytes, durations)
		if err != nil {
			writeDevError(w, err)
			log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), durations))
			return
		}

		body, err := formatOutputBytes(output)
		if err != nil {
			writeDevError(w, err)
			log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), durations))
			return
		}

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write(body); err != nil {
			log.Printf("dev: %s %s write_error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), durations))
		}
		log.Printf("dev: %s %s ok %s", r.Method, r.URL.Path, formatDurationParts(time.Since(start), durations))
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

type moduleChain func(context.Context, []byte, []time.Duration) (contentData, error)

func buildModuleChain(modules []string, opts options) (moduleChain, error) {
	if len(modules) == 0 {
		return func(ctx context.Context, input []byte, durations []time.Duration) (contentData, error) {
			_ = ctx
			_ = durations
			return contentData{bytes: input, encoding: dataEncodingRaw}, nil
		}, nil
	}

	moduleBodies := make([][]byte, len(modules))
	for i, modulePath := range modules {
		body, err := readModulePath(modulePath, opts)
		if err != nil {
			return nil, err
		}
		moduleBodies[i] = body
	}

	return func(ctx context.Context, input []byte, durations []time.Duration) (contentData, error) {
		if len(durations) > len(moduleBodies) {
			durations = durations[:len(moduleBodies)]
		}
		var output contentData
		cur := input
		for i, body := range moduleBodies {
			start := time.Now()
			nextOutput, err := runModuleWithInput(ctx, body, cur, opts)
			if i < len(durations) {
				durations[i] = time.Since(start)
			}
			if err != nil {
				return contentData{}, err
			}
			output = nextOutput
			cur = output.bytes
		}
		return output, nil
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

func writeDevError(w http.ResponseWriter, err error) {
	ts := time.Now().Format(time.RFC3339)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusInternalServerError)
	fmt.Fprintf(w, "<!doctype html><meta charset=\"utf-8\"><title>qip dev error</title><pre>%s\n%s</pre>", ts, html.EscapeString(err.Error()))
}

func formatDurationParts(total time.Duration, parts []time.Duration) string {
	totalMs := total.Milliseconds()
	if len(parts) == 0 {
		return fmt.Sprintf("duration_ms=%d", totalMs)
	}
	var b strings.Builder
	b.Grow(40 + len(parts)*6)
	b.WriteString("duration_ms=")
	b.WriteString(strconv.FormatInt(totalMs, 10))
	b.WriteString(" module_durations_ms=[")
	for i, part := range parts {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatInt(part.Milliseconds(), 10))
	}
	b.WriteByte(']')
	return b.String()
}
