package qinternal

import (
	"bufio"
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"unicode/utf8"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

const usageForm = "Usage: qip form [-v|--verbose] <wasm module URL or file>"

const (
	exportMemory           = "memory"
	exportInputPtr         = "input_ptr"
	exportInputUTF8Cap     = "input_utf8_cap"
	exportRun              = "run"
	exportOutputPtr        = "output_ptr"
	exportOutputUTF8Cap    = "output_utf8_cap"
	exportInputKeyPtr      = "input_key_ptr"
	exportInputKeySize     = "input_key_size"
	exportInputLabelPtr    = "input_label_ptr"
	exportInputLabelSize   = "input_label_size"
	exportErrorMessagePtr  = "error_message_ptr"
	exportErrorMessageSize = "error_message_size"
)

type formModule struct {
	mod              api.Module
	mem              api.Memory
	fnInputPtr       api.Function
	fnInputUTF8Cap   api.Function
	fnRun            api.Function
	fnOutputPtr      api.Function
	fnOutputUTF8Cap  api.Function
	fnInputKeyPtr    api.Function
	fnInputKeySize   api.Function
	fnInputLabelPtr  api.Function
	fnInputLabelSize api.Function
	fnErrorPtr       api.Function
	fnErrorSize      api.Function
}

func RunFormCommand(args []string) error {
	fs := flag.NewFlagSet("form", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var verbose bool
	fs.BoolVar(&verbose, "v", false, "enable verbose logging")
	fs.BoolVar(&verbose, "verbose", false, "enable verbose logging")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%s %w", usageForm, err)
	}

	rest := fs.Args()
	if len(rest) != 1 {
		return errors.New(usageForm)
	}
	modulePath := rest[0]

	body, err := readFormModulePath(modulePath, verbose)
	if err != nil {
		return err
	}

	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	compiled, err := runtime.CompileModule(ctx, body)
	if err != nil {
		return errors.New("Wasm module could not be compiled")
	}
	defer compiled.Close(ctx)

	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName("qip-form"))
	if err != nil {
		return errors.New("Wasm module could not be instantiated")
	}
	defer mod.Close(ctx)

	fm, err := resolveFormModule(mod)
	if err != nil {
		return err
	}

	return runFormInteractive(ctx, fm, os.Stdin, os.Stdout)
}

func readFormModulePath(path string, verbose bool) ([]byte, error) {
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
	if verbose {
		sum := sha256.Sum256(body)
		fmt.Fprintf(os.Stderr, "module sha256: %x\n", sum)
	}
	return body, nil
}

func resolveFormModule(mod api.Module) (formModule, error) {
	mem := mod.ExportedMemory(exportMemory)
	if mem == nil {
		return formModule{}, fmt.Errorf("Wasm module must export %s", exportMemory)
	}
	required := []struct {
		name string
		dst  *api.Function
	}{
		{name: exportInputPtr},
		{name: exportInputUTF8Cap},
		{name: exportRun},
		{name: exportOutputPtr},
		{name: exportOutputUTF8Cap},
		{name: exportInputKeyPtr},
		{name: exportInputKeySize},
		{name: exportInputLabelPtr},
		{name: exportInputLabelSize},
		{name: exportErrorMessagePtr},
		{name: exportErrorMessageSize},
	}

	out := formModule{mod: mod, mem: mem}
	for i := range required {
		fn := mod.ExportedFunction(required[i].name)
		if fn == nil {
			return formModule{}, fmt.Errorf("Wasm module must export %s", required[i].name)
		}
		switch required[i].name {
		case exportInputPtr:
			out.fnInputPtr = fn
		case exportInputUTF8Cap:
			out.fnInputUTF8Cap = fn
		case exportRun:
			out.fnRun = fn
		case exportOutputPtr:
			out.fnOutputPtr = fn
		case exportOutputUTF8Cap:
			out.fnOutputUTF8Cap = fn
		case exportInputKeyPtr:
			out.fnInputKeyPtr = fn
		case exportInputKeySize:
			out.fnInputKeySize = fn
		case exportInputLabelPtr:
			out.fnInputLabelPtr = fn
		case exportInputLabelSize:
			out.fnInputLabelSize = fn
		case exportErrorMessagePtr:
			out.fnErrorPtr = fn
		case exportErrorMessageSize:
			out.fnErrorSize = fn
		}
	}
	return out, nil
}

func runFormInteractive(ctx context.Context, fm formModule, stdin io.Reader, stdout io.Writer) error {
	reader := bufio.NewReader(stdin)
	var lastOutputSize int32
	hasRun := false

	for {
		errMsg, err := readExportedString(ctx, fm.mem, fm.fnErrorPtr, fm.fnErrorSize, exportErrorMessagePtr, exportErrorMessageSize)
		if err != nil {
			return err
		}
		if errMsg != "" {
			if _, err := fmt.Fprintf(stdout, "Error: %s\n", errMsg); err != nil {
				return err
			}
		}

		key, err := readExportedString(ctx, fm.mem, fm.fnInputKeyPtr, fm.fnInputKeySize, exportInputKeyPtr, exportInputKeySize)
		if err != nil {
			return err
		}
		key = strings.TrimSpace(key)
		if key == "" {
			if !hasRun {
				lastOutputSize, err = callRunSize(ctx, fm.fnRun, 0)
				if err != nil {
					return err
				}
				hasRun = true
			}
			outBytes, err := readOutputBytes(ctx, fm, lastOutputSize)
			if err != nil {
				return err
			}
			if len(outBytes) > 0 {
				if _, err := io.WriteString(stdout, string(outBytes)); err != nil {
					return err
				}
				if len(outBytes) > 0 && outBytes[len(outBytes)-1] != '\n' {
					if _, err := io.WriteString(stdout, "\n"); err != nil {
						return err
					}
				}
			}
			return nil
		}
		label, err := readExportedString(ctx, fm.mem, fm.fnInputLabelPtr, fm.fnInputLabelSize, exportInputLabelPtr, exportInputLabelSize)
		if err != nil {
			return err
		}
		prompt := strings.TrimSpace(label)
		if prompt == "" {
			prompt = key
		}
		if _, err := fmt.Fprintf(stdout, "%s: ", prompt); err != nil {
			return err
		}

		line, readErr := reader.ReadString('\n')
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return readErr
		}
		if errors.Is(readErr, io.EOF) && len(line) == 0 {
			return errors.New("form input aborted")
		}
		value := strings.TrimRight(line, "\r\n")

		inputPtr, err := callNoArgI32(ctx, fm.fnInputPtr, exportInputPtr)
		if err != nil {
			return err
		}
		inputCap, err := callNoArgI32(ctx, fm.fnInputUTF8Cap, exportInputUTF8Cap)
		if err != nil {
			return err
		}
		if inputPtr < 0 || inputCap < 0 {
			return fmt.Errorf("module returned invalid input memory values: ptr=%d cap=%d", inputPtr, inputCap)
		}

		valueBytes := []byte(value)
		if len(valueBytes) > int(inputCap) {
			return fmt.Errorf("input value exceeds module input_utf8_cap (%d > %d)", len(valueBytes), inputCap)
		}
		if len(valueBytes) > 0 && !fm.mem.Write(uint32(inputPtr), valueBytes) {
			return errors.New("failed to write form input to wasm memory")
		}

		lastOutputSize, err = callRunSize(ctx, fm.fnRun, int32(len(valueBytes)))
		if err != nil {
			return err
		}
		hasRun = true
	}
}

func readOutputBytes(ctx context.Context, fm formModule, outputSize int32) ([]byte, error) {
	if outputSize < 0 {
		return nil, fmt.Errorf("run returned negative output size: %d", outputSize)
	}
	if outputSize == 0 {
		return nil, nil
	}

	outPtr, err := callNoArgI32(ctx, fm.fnOutputPtr, exportOutputPtr)
	if err != nil {
		return nil, err
	}
	outCap, err := callNoArgI32(ctx, fm.fnOutputUTF8Cap, exportOutputUTF8Cap)
	if err != nil {
		return nil, err
	}
	if outPtr < 0 || outCap < 0 {
		return nil, fmt.Errorf("module returned invalid output memory values: ptr=%d cap=%d", outPtr, outCap)
	}
	if outputSize > outCap {
		return nil, fmt.Errorf("run output size exceeds output_utf8_cap (%d > %d)", outputSize, outCap)
	}
	b, ok := fm.mem.Read(uint32(outPtr), uint32(outputSize))
	if !ok {
		return nil, errors.New("output bytes exceed wasm memory bounds")
	}
	if !utf8.Valid(b) {
		return nil, errors.New("module output is not valid UTF-8")
	}
	out := make([]byte, len(b))
	copy(out, b)
	return out, nil
}

func readExportedString(ctx context.Context, mem api.Memory, ptrFn api.Function, sizeFn api.Function, ptrName string, sizeName string) (string, error) {
	ptr, err := callNoArgI32(ctx, ptrFn, ptrName)
	if err != nil {
		return "", err
	}
	n, err := callNoArgI32(ctx, sizeFn, sizeName)
	if err != nil {
		return "", err
	}
	if ptr < 0 || n < 0 {
		return "", fmt.Errorf("module returned invalid pointer/size for %s/%s: ptr=%d size=%d", ptrName, sizeName, ptr, n)
	}
	if n == 0 {
		return "", nil
	}
	b, ok := mem.Read(uint32(ptr), uint32(n))
	if !ok {
		return "", fmt.Errorf("%s/%s exceed wasm memory bounds", ptrName, sizeName)
	}
	if !utf8.Valid(b) {
		return "", fmt.Errorf("%s/%s must be valid UTF-8", ptrName, sizeName)
	}
	return string(b), nil
}

func callRunSize(ctx context.Context, fn api.Function, inputSize int32) (int32, error) {
	res, err := fn.Call(ctx, uint64(uint32(inputSize)))
	if err != nil {
		return 0, fmt.Errorf("run() failed: %w", err)
	}
	if len(res) != 1 {
		return 0, errors.New("run() returned unexpected result arity")
	}
	return int32(uint32(res[0])), nil
}

func callNoArgI32(ctx context.Context, fn api.Function, name string) (int32, error) {
	res, err := fn.Call(ctx)
	if err != nil {
		return 0, fmt.Errorf("%s() failed: %w", name, err)
	}
	if len(res) != 1 {
		return 0, fmt.Errorf("%s() returned unexpected result arity", name)
	}
	return int32(uint32(res[0])), nil
}
