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

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

const usageForm = "Usage: qip form [-v|--verbose] <wasm module URL or file>"

const (
	exportMemory          = "memory"
	exportInputPtr        = "input_ptr"
	exportInputUTF8Cap    = "input_utf8_cap"
	exportRun             = "run"
	exportOutputPtr       = "output_ptr"
	exportOutputUTF8Cap   = "output_utf8_cap"
	exportInputStep       = "input_step"
	exportInputMaxStep    = "input_max_step"
	exportInputKeyPtr     = "input_key_ptr"
	exportInputKeyLen     = "input_key_len"
	exportInputLabelPtr   = "input_label_ptr"
	exportInputLabelLen   = "input_label_len"
	exportErrorMessagePtr = "error_message_ptr"
	exportErrorMessageLen = "error_message_len"
)

type formModule struct {
	mod             api.Module
	mem             api.Memory
	fnInputPtr      api.Function
	fnInputUTF8Cap  api.Function
	fnRun           api.Function
	fnOutputPtr     api.Function
	fnOutputUTF8Cap api.Function
	fnInputStep     api.Function
	fnInputMaxStep  api.Function
	fnInputKeyPtr   api.Function
	fnInputKeyLen   api.Function
	fnInputLabelPtr api.Function
	fnInputLabelLen api.Function
	fnErrorPtr      api.Function
	fnErrorLen      api.Function
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
	runtime := wazero.NewRuntime(ctx)
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
		{name: exportInputStep},
		{name: exportInputMaxStep},
		{name: exportInputKeyPtr},
		{name: exportInputKeyLen},
		{name: exportInputLabelPtr},
		{name: exportInputLabelLen},
		{name: exportErrorMessagePtr},
		{name: exportErrorMessageLen},
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
		case exportInputStep:
			out.fnInputStep = fn
		case exportInputMaxStep:
			out.fnInputMaxStep = fn
		case exportInputKeyPtr:
			out.fnInputKeyPtr = fn
		case exportInputKeyLen:
			out.fnInputKeyLen = fn
		case exportInputLabelPtr:
			out.fnInputLabelPtr = fn
		case exportInputLabelLen:
			out.fnInputLabelLen = fn
		case exportErrorMessagePtr:
			out.fnErrorPtr = fn
		case exportErrorMessageLen:
			out.fnErrorLen = fn
		}
	}
	return out, nil
}

func runFormInteractive(ctx context.Context, fm formModule, stdin io.Reader, stdout io.Writer) error {
	reader := bufio.NewReader(stdin)
	var lastOutputLen int32
	hasRun := false

	for {
		step, err := callNoArgI32(ctx, fm.fnInputStep, exportInputStep)
		if err != nil {
			return err
		}
		maxStep, err := callNoArgI32(ctx, fm.fnInputMaxStep, exportInputMaxStep)
		if err != nil {
			return err
		}
		if step < 0 || maxStep < 0 {
			return fmt.Errorf("module returned invalid step values: step=%d max=%d", step, maxStep)
		}

		if step > maxStep {
			if !hasRun {
				lastOutputLen, err = callRunLen(ctx, fm.fnRun, 0)
				if err != nil {
					return err
				}
				hasRun = true
			}
			outBytes, err := readOutputBytes(ctx, fm, lastOutputLen)
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

		errMsg, err := readExportedString(ctx, fm.mem, fm.fnErrorPtr, fm.fnErrorLen, exportErrorMessagePtr, exportErrorMessageLen)
		if err != nil {
			return err
		}
		if errMsg != "" {
			if _, err := fmt.Fprintf(stdout, "Error: %s\n", errMsg); err != nil {
				return err
			}
		}

		key, err := readExportedString(ctx, fm.mem, fm.fnInputKeyPtr, fm.fnInputKeyLen, exportInputKeyPtr, exportInputKeyLen)
		if err != nil {
			return err
		}
		label, err := readExportedString(ctx, fm.mem, fm.fnInputLabelPtr, fm.fnInputLabelLen, exportInputLabelPtr, exportInputLabelLen)
		if err != nil {
			return err
		}
		prompt := strings.TrimSpace(label)
		if prompt == "" {
			prompt = strings.TrimSpace(key)
		}
		if prompt == "" {
			prompt = fmt.Sprintf("Step %d", step+1)
		}
		if _, err := fmt.Fprintf(stdout, "[%d/%d] %s: ", step+1, maxStep+1, prompt); err != nil {
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

		lastOutputLen, err = callRunLen(ctx, fm.fnRun, int32(len(valueBytes)))
		if err != nil {
			return err
		}
		hasRun = true
	}
}

func readOutputBytes(ctx context.Context, fm formModule, outLen int32) ([]byte, error) {
	if outLen < 0 {
		return nil, fmt.Errorf("run returned negative output length: %d", outLen)
	}
	if outLen == 0 {
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
	if outLen > outCap {
		return nil, fmt.Errorf("run output length exceeds output_utf8_cap (%d > %d)", outLen, outCap)
	}
	b, ok := fm.mem.Read(uint32(outPtr), uint32(outLen))
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

func readExportedString(ctx context.Context, mem api.Memory, ptrFn api.Function, lenFn api.Function, ptrName string, lenName string) (string, error) {
	ptr, err := callNoArgI32(ctx, ptrFn, ptrName)
	if err != nil {
		return "", err
	}
	n, err := callNoArgI32(ctx, lenFn, lenName)
	if err != nil {
		return "", err
	}
	if ptr < 0 || n < 0 {
		return "", fmt.Errorf("module returned invalid pointer/length for %s/%s: ptr=%d len=%d", ptrName, lenName, ptr, n)
	}
	if n == 0 {
		return "", nil
	}
	b, ok := mem.Read(uint32(ptr), uint32(n))
	if !ok {
		return "", fmt.Errorf("%s/%s exceed wasm memory bounds", ptrName, lenName)
	}
	if !utf8.Valid(b) {
		return "", fmt.Errorf("%s/%s must be valid UTF-8", ptrName, lenName)
	}
	return string(b), nil
}

func callRunLen(ctx context.Context, fn api.Function, inputLen int32) (int32, error) {
	res, err := fn.Call(ctx, uint64(uint32(inputLen)))
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
