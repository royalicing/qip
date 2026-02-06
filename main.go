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
	"sync/atomic"
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

const usageMain = "Usage: qip <command> [args]\n\nCommands:\n  run   Run a chain of wasm modules on input\n  image Run wasm filters on an input image\n  dev   Start a dev server to re-run modules per request\n  help  Show command help"
const usageRun = "Usage: qip run [-v] [-i <input>] <wasm module URL or file>..."
const usageImage = "Usage: qip image -i <input image path> -o <output image path> [-v] <wasm module URL or file>"
const usageDev = "Usage: qip dev -i <input> [-p <port>] [-v|--verbose] [-- <module1> <module2> ...]"
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

func runModuleWithInput(ctx context.Context, runtime wazero.Runtime, compiled wazero.CompiledModule, inputBytes []byte, opts options, moduleName string) (output contentData, instantiation time.Duration, returnErr error) {
	instStart := time.Now()
	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName(moduleName))
	if err != nil {
		returnErr = errors.New("Wasm module could not be instantiated")
		return
	}
	defer mod.Close(ctx)
	instantiation = time.Since(instStart)

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
		} else if outputPtr == uint32(inputPtr) {
			// Allow in-place output when output_ptr aliases input_ptr.
			outputCap = uint32(inputCap)
			output.encoding = input.encoding
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
		if outputPtr == uint32(inputPtr) && outputItemFactor == 1 && outputCountBytes <= uint32(len(inputBytes)) {
			// Fast path for in-place identity output.
			output.bytes = inputBytes[:outputCountBytes]
		} else {
			outputBytes, _ := mod.Memory().Read(outputPtr, uint32(outputCountBytes))
			output.bytes = outputBytes
		}
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

	return output, instantiation, nil
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

	chain, err := buildModuleChain(context.Background(), modules, opts)
	if err != nil {
		gameOver("%v", err)
	}
	defer chain.Close(context.Background())

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	mux := http.NewServeMux()
	var requestID uint64
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		reqID := atomic.AddUint64(&requestID, 1)
		if r.Method != http.MethodGet {
			emptyDurations := []time.Duration{}
			emptyInst := []time.Duration{}
			w.WriteHeader(http.StatusMethodNotAllowed)
			log.Printf("dev: %s %s %s", r.Method, r.URL.Path, formatDurationParts(time.Since(start), emptyDurations, emptyInst))
			return
		}

		inputBytes, err := os.ReadFile(inputPath)
		if err != nil {
			emptyDurations := []time.Duration{}
			emptyInst := []time.Duration{}
			writeDevError(w, err)
			log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), emptyDurations, emptyInst))
			return
		}

		ctx := context.Background()
		ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
		defer cancel()

		result, err := chain.run(ctx, inputBytes, reqID)
		if err != nil {
			writeDevError(w, err)
			log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
			return
		}

		body, err := formatOutputBytes(result.output)
		if err != nil {
			writeDevError(w, err)
			log.Printf("dev: %s %s error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
			return
		}

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write(body); err != nil {
			log.Printf("dev: %s %s write_error=%v %s", r.Method, r.URL.Path, err, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
		}
		log.Printf("dev: %s %s ok %s", r.Method, r.URL.Path, formatDurationParts(time.Since(start), result.metrics.moduleDurations, result.metrics.instantiationDurations))
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
