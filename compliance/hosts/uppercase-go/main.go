// Self-contained example: testing a Go-stdlib uppercase implementation
// against the QIP Content Compliance oracle for Unicode 17 uppercase.
//
//	cd compliance/hosts/uppercase-go && go run .
//
// The implementation under test is strings.ToUpper-style per-rune mapping
// from the Go standard library (unicode.ToUpper), wrapped so invalid UTF-8
// bytes pass through unchanged. wazero hosts the Compliance oracle (Go's
// stdlib has no wasm runtime; the *implementation* is stdlib-only).
// Exit code 0 = compliant, 1 = divergences found.
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"unicode"
	"unicode/utf8"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

// --- implementation under test (Go stdlib) ---------------------------------

func upperBytes(input []byte) []byte {
	out := make([]byte, 0, len(input))
	for i := 0; i < len(input); {
		r, size := utf8.DecodeRune(input[i:])
		if r == utf8.RuneError && size <= 1 {
			out = append(out, input[i]) // invalid byte passes through
			i++
			continue
		}
		out = utf8.AppendRune(out, unicode.ToUpper(r))
		i += size
	}
	return out
}

// --- qip compliance bridge ---------------------------------------------------

type failure struct {
	ordinal  uint64
	kind     string
	input    []byte
	expected []byte
	actual   []byte
}

func main() {
	wasmPath := filepath.Join("..", "..", "unicode-17-uppercase.comply.wasm")
	wasmBytes, err := os.ReadFile(wasmPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	ctx := context.Background()
	runtime := wazero.NewRuntime(ctx)
	defer runtime.Close(ctx)

	var failures []failure
	var equalityCases, renderIntoCases int

	read := func(mod api.Module, ptr, length uint32) []byte {
		view, ok := mod.Memory().Read(ptr, length)
		if !ok {
			panic("component pointer out of range")
		}
		return append([]byte(nil), view...)
	}

	_, err = runtime.NewHostModuleBuilder("qip").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, mod api.Module, ordinal uint64, inPtr, inLen, expPtr, expLen uint32) int32 {
			equalityCases++
			input := read(mod, inPtr, inLen)
			expected := read(mod, expPtr, expLen)
			actual := upperBytes(input)
			if string(actual) != string(expected) {
				failures = append(failures, failure{ordinal, "equal", input, expected, actual})
				return 0
			}
			return 1
		}).
		Export("must_render_exactly").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, mod api.Module, ordinal uint64, inPtr, inLen uint32) int32 {
			// A pure function cannot trap; any expect-trap case is a failure here.
			failures = append(failures, failure{ordinal: ordinal, kind: "trap", input: read(mod, inPtr, inLen)})
			return 0
		}).
		Export("must_trap").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, mod api.Module, ordinal uint64, inPtr, inLen, outPtr, outCap uint32) int32 {
			output := upperBytes(read(mod, inPtr, inLen))
			if uint32(len(output)) > outCap {
				return -2
			}
			if !mod.Memory().Write(outPtr, output) {
				return -2
			}
			return int32(len(output))
		}).
		Export("must_render_into").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, mod api.Module, ordinal uint64, msgPtr, msgLen uint32) int32 {
			failures = append(failures, failure{ordinal: ordinal, kind: "must_render_into"})
			return 1
		}).
		Export("must_render_into_emit_error").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, ordinal uint64, errorCount uint32) int32 {
			renderIntoCases++
			return 1
		}).
		Export("must_render_into_finish").
		Instantiate(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	component, err := runtime.Instantiate(ctx, wasmBytes)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	results, err := component.ExportedFunction("comply").Call(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	declared := int32(results[0])

	// --- report ---------------------------------------------------------------

	fmt.Printf("impl: Go stdlib unicode.ToUpper per rune (unicode.Version %s — simple mappings only)\n", unicode.Version)
	fmt.Printf("cases: %d declared (%d equality, %d must_render_into)\n", declared, equalityCases, renderIntoCases)
	if len(failures) == 0 {
		fmt.Println("COMPLIANT: all cases pass")
		return
	}
	fmt.Printf("NON-COMPLIANT: %d failing case(s)\n", len(failures))
	for i, f := range failures {
		if i >= 10 {
			fmt.Printf("  … and %d more\n", len(failures)-10)
			break
		}
		if f.kind == "equal" {
			fmt.Printf("  case %d: input=%q\n", f.ordinal, f.input)
			fmt.Printf("    expected %x\n", f.expected)
			fmt.Printf("    actual   %x\n", f.actual)
		} else {
			fmt.Printf("  case %d: %s failed\n", f.ordinal, f.kind)
		}
	}
	os.Exit(1)
}
