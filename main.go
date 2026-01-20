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
	"image"
	"image/draw"
	_ "image/jpeg"
	"image/png"
	"io"
	"net/http"
	"os"
	"strings"
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

func main() {
	args := os.Args[1:]

	if len(args) == 0 {
		gameOver("Usage: <wasm module URL or file>")
	}

	if args[0] == "run" {
		run(args[1:])
	} else if args[0] == "image" {
		imageCmd(args[1:])
	} else {
		run(args)
	}
}

func readModulePath(path string) []byte {
	var body []byte

	if strings.HasPrefix(path, "https://") {
		resp, err := http.Get(path)
		if err != nil {
			gameOver("Error fetching URL: %v", err)
		}
		defer resp.Body.Close()

		body, err = io.ReadAll(resp.Body)
		if err != nil {
			gameOver("Error reading response: %v", err)
		}
	} else {
		var err error
		body, err = os.ReadFile(path)
		if err != nil {
			gameOver("Error reading file: %v", err)
		}
	}

	moduleDigest := sha256.Sum256(body)
	fmt.Fprintf(os.Stderr, "module %s sha256: %x\n", path, moduleDigest)

	return body
}

func run(args []string) {
	if len(args) < 1 {
		gameOver("Usage: <wasm module URL or file>")
	}

	body := readModulePath(args[0])

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

	inputDigest := sha256.Sum256(input)
	fmt.Fprintf(os.Stderr, "input sha256: %x\n", inputDigest)

	output, err := runModuleWithInput(ctx, body, input)
	if err != nil {
		gameOver("%v", err)
	} else if output.encoding == dataEncodingRaw {
		if _, err := os.Stdout.Write(output.bytes); err != nil {
			gameOver("Error writing raw output: %v", err)
		}
	} else if output.encoding == dataEncodingUTF8 {
		fmt.Printf("%s\n", output.bytes)
	} else if output.encoding == dataEncodingArrayI32 {
		fmt.Fprintln(os.Stderr, output.bytes)

		count := len(output.bytes) / 4
		if count >= 1 {
			bufSize := count * 9
			writer := bufio.NewWriterSize(os.Stdout, bufSize)
			defer writer.Flush()
			for i := 0; i < count; i++ {
				v := binary.LittleEndian.Uint32(output.bytes[i*4:])
				fmt.Fprintf(os.Stderr, "u32: %d\n", v)
				if _, err := fmt.Fprintf(writer, "%08x\n", v); err != nil {
					gameOver("Error writing i32 output: %v", err)
				}
			}
		}
	}
}

func imageCmd(args []string) {
	var inputImagePath string
	var outputImagePath string
	fs := flag.NewFlagSet("image", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&inputImagePath, "i", "", "input image path")
	fs.StringVar(&outputImagePath, "o", "", "output image path")
	if err := fs.Parse(args); err != nil {
		gameOver("Usage: image -i <input image path> -o <output image path> <wasm module URL or file>")
	}
	modules := fs.Args()
	if len(modules) != 1 || inputImagePath == "" || outputImagePath == "" {
		gameOver("Usage: image -i <input image path> -o <output image path> <wasm module URL or file>")
	}

	body := readModulePath(modules[0])

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
	_ = inputRGBA
	bounds := inputRGBA.Bounds()
	outputRGBA := image.NewRGBA(bounds)
	outputPix := outputRGBA.Pix
	outputStride := outputRGBA.Stride
	r := wazero.NewRuntime(ctx)
	defer r.Close(ctx)
	mod, err := r.InstantiateWithConfig(ctx, body, wazero.NewModuleConfig())
	if err != nil {
		gameOver("Wasm module could not be compiled")
	}
	tileFunc := mod.ExportedFunction("tile_rgba_f32_64x64")
	if tileFunc == nil {
		gameOver("Wasm module must export tile_rgba_f32_64x64")
	}
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
	const tileSize = 64
	pix := inputRGBA.Pix
	stride := inputRGBA.Stride
	width := bounds.Dx()
	height := bounds.Dy()
	tileF32 := make([]float32, tileSize*tileSize*4)
	tileBytes := unsafe.Slice((*byte)(unsafe.Pointer(&tileF32[0])), len(tileF32)*4)
	if uint64(len(tileBytes)) > inputCap {
		gameOver("Tile buffer exceeds module input_bytes_cap")
	}
	const inv255 = 1.0 / 255.0
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
			if !mem.Write(inputPtr, tileBytes) {
				gameOver("Could not write tile to wasm memory")
			}
			if _, err := tileFunc.Call(ctx, uint64(inputPtr)); err != nil {
				gameOver("Error running tile_rgba_f32_64x64: %v", err)
			}
			tileOutBytes, ok := mem.Read(inputPtr, uint32(len(tileBytes)))
			if !ok {
				gameOver("Could not read tile from wasm memory")
			}
			tileOutF32 := unsafe.Slice((*float32)(unsafe.Pointer(&tileOutBytes[0])), len(tileF32))
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

func runModuleWithInput(ctx context.Context, modBytes []byte, inputBytes []byte) (output contentData, returnErr error) {
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
			gameOver("Module returned more bytes than its stated capacity")
		}
		outputBytes, _ := mod.Memory().Read(outputPtr, uint32(outputCountBytes))
		output.bytes = outputBytes
	} else {
		fmt.Printf("Ran: %d\n", runResult[0])
	}

	// Detect if outputBytes are wasm module by checking for magic number
	// if len(outputBytes) >= 4 && outputBytes[0] == 0x00 && outputBytes[1] == 0x61 && outputBytes[2] == 0x73 && outputBytes[3] == 0x6D {
	// }

	return output, nil
}

func gameOver(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
