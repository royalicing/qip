package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

type dataEncoding uint8

const (
	dataEncodingRaw dataEncoding = iota
	dataEncodingUTF8
)

type contentData struct {
	bytes    []byte
	encoding dataEncoding
}

func main() {
	if len(os.Args) < 2 {
		gameOver("Usage: %s <URL or file>", os.Args[0])
	}

	path := os.Args[1]
	var body []byte
	var status string

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
		status = resp.Status
	} else {
		var err error
		body, err = os.ReadFile(path)
		if err != nil {
			gameOver("Error reading file: %v", err)
		}
	}

	moduleDigest := sha256.Sum256(body)
	fmt.Fprintf(os.Stderr, "module sha256: %x\n", moduleDigest)

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
	}

	if status != "" {
		fmt.Printf("Status: %s\n", status)
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

func runModuleWithInput(ctx context.Context, modBytes []byte, input []byte) (output contentData, returnErr error) {
	r := wazero.NewRuntime(ctx)
	defer r.Close(ctx)

	mod, err := r.InstantiateWithConfig(ctx, modBytes, wazero.NewModuleConfig())
	if err != nil {
		returnErr = errors.New("Wasm module could not be compiled")
		return
	}

	// Get input_ptr and input_cap (required)
	inputPtr, ok := getExportedValue(ctx, mod, "input_ptr")
	if !ok {
		returnErr = errors.New("Wasm module must export input_ptr as global or function")
		return
	}

	inputCap, ok := getExportedValue(ctx, mod, "input_cap")
	if !ok {
		returnErr = errors.New("Wasm module must export input_cap as global or function")
		return
	}

	var outputPtr, outputCap uint32
	if ptr, ok := getExportedValue(ctx, mod, "output_ptr"); ok {
		outputPtr = uint32(ptr)

		if cap, ok := getExportedValue(ctx, mod, "output_utf8_cap"); ok {
			outputCap = uint32(cap)
			output.encoding = dataEncodingUTF8
		} else if cap, ok := getExportedValue(ctx, mod, "output_bytes_cap"); ok {
			outputCap = uint32(cap)
			output.encoding = dataEncodingRaw
		} else {
			returnErr = errors.New("Wasm module must export output_utf8_cap or output_bytes_cap function")
			return
		}
	}

	runFunc := mod.ExportedFunction("run")

	// inputPtrResult, err := mod.ExportedFunction("input_ptr").Call(ctx)
	// if err != nil {
	// 	gameOver("Wasm module must export an input_ptr() function")
	// }

	var inputSize = uint64(len(input))
	if inputSize > inputCap {
		returnErr = errors.New("Input is too large")
		return
	}

	if !mod.Memory().Write(uint32(inputPtr), input) {
		returnErr = errors.New("Could not write input")
		return
	}

	runResult, returnErr := runFunc.Call(ctx, inputSize)
	if returnErr != nil {
		return
	}

	if outputCap > 0 {
		outputBytes, _ := mod.Memory().Read(outputPtr, uint32(runResult[0]))
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
