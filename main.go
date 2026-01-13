package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/tetratelabs/wazero"
)

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

	digest := sha256.Sum256(body)
	fmt.Printf("SHA256: %x\n", digest)

	ctx := context.Background()
	ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	
	r := wazero.NewRuntime(ctx)
	defer r.Close(ctx)

	// _, err := r.NewHostModuleBuilder("env").
	// 	NewFunctionBuilder().WithFunc(logString).Export("log").
	// 	Instantiate(ctx)
	// if err != nil {
	// 	// Do nothing
	// }

	mod, err := r.InstantiateWithConfig(ctx, body,
		wazero.NewModuleConfig().WithStdout(os.Stdout).WithStderr(os.Stderr))
	if err != nil {
		gameOver("Wasm module could not be compiled")
	}

	inputPtr := mod.ExportedGlobal("input_ptr").Get()
	inputCap := mod.ExportedGlobal("input_cap").Get()
	outputPtr := mod.ExportedGlobal("output_ptr").Get()
	outputCap := mod.ExportedGlobal("output_cap").Get()
	runFunc := mod.ExportedFunction("run")

	// inputPtrResult, err := mod.ExportedFunction("input_ptr").Call(ctx)
	// if err != nil {
	// 	gameOver("Wasm module must export an input_ptr() function")
	// }

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

	var inputSize = uint64(len(input))
	fmt.Printf("It worked! (%d %d)\n", inputPtr, inputCap)
	fmt.Printf("Input (%d %d max %d)\n", inputPtr, inputSize, inputCap)
	fmt.Printf("Output (%d %d)\n", outputPtr, outputCap)

	if !mod.Memory().Write(uint32(inputPtr), input) {
		gameOver("Could not write input")
	}

	fmt.Printf("About to run\n")
	runResult, err := runFunc.Call(ctx, inputSize)
	if err != nil {
		gameOver("Failed to run: %s", err)
	}

	fmt.Printf("Ran: %d\n", runResult[0])

	if status != "" {
		fmt.Printf("Status: %s\n", status)
	}
	// fmt.Printf("\nBody:\n%s\n", body)
}

func gameOver(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
