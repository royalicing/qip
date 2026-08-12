package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"image"
	"mime"
	"slices"
	"strings"
	"time"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

func getExportedValue(ctx context.Context, mod api.Module, name string) (uint64, bool, error) {
	fn := mod.ExportedFunction(name)
	if fn == nil {
		if mod.ExportedGlobal(name) != nil {
			return 0, true, fmt.Errorf("Wasm module must export %s() -> i32", name)
		}
		return 0, false, nil
	}
	params := fn.Definition().ParamTypes()
	results := fn.Definition().ResultTypes()
	if len(params) != 0 || len(results) != 1 || results[0] != api.ValueTypeI32 {
		return 0, true, fmt.Errorf("Wasm module must export %s() -> i32", name)
	}
	result, err := fn.Call(ctx)
	if err != nil {
		return 0, true, fmt.Errorf("%s() call failed: %w", name, err)
	}
	return result[0], true, nil
}

func hasExportedValue(mod api.Module, name string) bool {
	return mod.ExportedFunction(name) != nil || mod.ExportedGlobal(name) != nil
}

func normalizeIncomingContentType(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if isCanonicalMultipartFormDataContentType(value) {
		return value
	}
	mediaType, _, err := mime.ParseMediaType(value)
	if err == nil && mediaType != "" {
		return strings.ToLower(mediaType)
	}
	if cut := strings.IndexByte(value, ';'); cut != -1 {
		value = strings.TrimSpace(value[:cut])
	}
	return strings.ToLower(value)
}

const multipartFormDataContentTypePrefix = "multipart/form-data;boundary=uuid-"

func isCanonicalMultipartFormDataContentType(value string) bool {
	if len(value) != len(multipartFormDataContentTypePrefix)+36 || !strings.HasPrefix(value, multipartFormDataContentTypePrefix) {
		return false
	}
	uuid := value[len(multipartFormDataContentTypePrefix):]
	for i := range uuid {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if uuid[i] != '-' {
				return false
			}
			continue
		}
		if !((uuid[i] >= '0' && uuid[i] <= '9') || (uuid[i] >= 'a' && uuid[i] <= 'f')) {
			return false
		}
	}
	return true
}

func validateDeclaredContentType(value string) (string, error) {
	if value == "" {
		return "", errors.New("content type is empty")
	}
	if strings.TrimSpace(value) != value {
		return "", fmt.Errorf("content type %q must not include whitespace", value)
	}
	if strings.ToLower(value) != value {
		return "", fmt.Errorf("content type %q must be lowercase", value)
	}
	if strings.Contains(value, ",") {
		return "", errors.New("content type must contain exactly one MIME type")
	}
	if isCanonicalMultipartFormDataContentType(value) {
		return value, nil
	}
	mediaType, params, err := mime.ParseMediaType(value)
	if err != nil {
		return "", fmt.Errorf("invalid content type %q: %w", value, err)
	}
	if mediaType == "" {
		return "", errors.New("content type is empty")
	}
	if len(params) > 0 {
		return "", fmt.Errorf("content type %q has parameters outside the canonical multipart/form-data boundary exception", value)
	}
	if strings.Contains(mediaType, "*") {
		return "", fmt.Errorf("content type %q must not include media ranges", value)
	}
	if mediaType != value {
		return "", fmt.Errorf("content type %q must be one canonical MIME type", value)
	}
	return value, nil
}

func readOptionalModuleContentType(ctx context.Context, mod api.Module, prefix string) (string, bool, error) {
	ptrName := prefix + "_content_type_ptr"
	sizeName := prefix + "_content_type_size"

	ptr, hasPtr, err := getExportedValue(ctx, mod, ptrName)
	if err != nil {
		return "", false, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	size, hasSize, err := getExportedValue(ctx, mod, sizeName)
	if err != nil {
		return "", false, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if hasPtr != hasSize {
		return "", false, fmt.Errorf("module must export both %s and %s together", ptrName, sizeName)
	}
	if !hasPtr {
		return "", false, nil
	}
	if size == 0 {
		return "", false, fmt.Errorf("module export %s must be non-empty when present", sizeName)
	}

	mem := mod.Memory()
	raw, ok := mem.Read(uint32(ptr), uint32(size))
	if !ok {
		return "", false, fmt.Errorf("failed to read %s bytes from module memory", prefix)
	}
	mediaType, err := validateDeclaredContentType(string(raw))
	if err != nil {
		return "", false, fmt.Errorf("invalid %s content type metadata: %w", prefix, err)
	}
	return mediaType, true, nil
}

type runModuleContract struct {
	inputPtr                     uint64
	inputCapBytes                uint64
	inputEncoding                dataEncoding
	hasOutput                    bool
	outputCapBytes               uint64
	outputEncoding               dataEncoding
	declaredInputContentType     string
	hasDeclaredInputContentType  bool
	declaredOutputContentType    string
	hasDeclaredOutputContentType bool
}

func inspectRunModuleContract(ctx context.Context, mod api.Module) (runModuleContract, error) {
	var contract runModuleContract
	if mod.Memory() == nil {
		return contract, errors.New("Wasm module must export memory")
	}

	renderFunc := mod.ExportedFunction("render")
	if renderFunc == nil {
		return contract, errors.New("Wasm module must export render(i32) -> i32")
	}
	params := renderFunc.Definition().ParamTypes()
	results := renderFunc.Definition().ResultTypes()
	if len(params) != 1 || params[0] != api.ValueTypeI32 || len(results) != 1 || results[0] != api.ValueTypeI32 {
		return contract, errors.New("Wasm module must export render(i32) -> i32")
	}

	inputPtr, ok, err := getExportedValue(ctx, mod, "input_ptr")
	if err != nil {
		return contract, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !ok {
		return contract, errors.New("Wasm module must export input_ptr() -> i32")
	}
	contract.inputPtr = inputPtr

	inputCap, ok, err := getExportedValue(ctx, mod, "input_utf8_cap")
	if err != nil {
		return contract, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if ok {
		contract.inputEncoding = dataEncodingUTF8
	} else if inputCap, ok, err = getExportedValue(ctx, mod, "input_bytes_cap"); err != nil {
		return contract, wasmruntime.HumanizeExecutionError(ctx, err)
	} else if ok {
		contract.inputEncoding = dataEncodingRaw
	} else {
		return contract, errors.New("Wasm module must export input_utf8_cap() -> i32 or input_bytes_cap() -> i32")
	}
	contract.inputCapBytes = inputCap

	hasOutputPtr := hasExportedValue(mod, "output_ptr")
	if hasOutputPtr {
		contract.hasOutput = true
		outputCap, ok, err := getExportedValue(ctx, mod, "output_utf8_cap")
		if err != nil {
			return contract, wasmruntime.HumanizeExecutionError(ctx, err)
		}
		if ok {
			contract.outputEncoding = dataEncodingUTF8
		} else if outputCap, ok, err = getExportedValue(ctx, mod, "output_bytes_cap"); err != nil {
			return contract, wasmruntime.HumanizeExecutionError(ctx, err)
		} else if ok {
			contract.outputEncoding = dataEncodingRaw
		} else {
			return contract, errors.New("Wasm module must export output_utf8_cap() -> i32 or output_bytes_cap() -> i32")
		}
		contract.outputCapBytes = outputCap
	}

	contract.declaredInputContentType, contract.hasDeclaredInputContentType, err = readOptionalModuleContentType(ctx, mod, "input")
	if err != nil {
		return contract, err
	}
	contract.declaredOutputContentType, contract.hasDeclaredOutputContentType, err = readOptionalModuleContentType(ctx, mod, "output")
	if err != nil {
		return contract, err
	}
	return contract, nil
}

func resolveRunModuleContentType(contract runModuleContract, incomingContentType string, allowMissingInputContentType bool, checking contentTypeCheckingMode, moduleName string) (effectiveInputType string, outputType string, err error) {
	incomingContentType = normalizeIncomingContentType(incomingContentType)
	effectiveInputType = incomingContentType
	if effectiveInputType == "" && contract.hasDeclaredInputContentType && allowMissingInputContentType {
		effectiveInputType = contract.declaredInputContentType
	}

	if checking == ContentTypeCheckingStrong && contract.hasDeclaredInputContentType {
		if effectiveInputType == "" {
			return "", "", fmt.Errorf("content type check failed for %s: module expects %q but pipeline content type is unspecified", moduleName, contract.declaredInputContentType)
		}
		if effectiveInputType != contract.declaredInputContentType {
			return "", "", fmt.Errorf("content type check failed for %s: module expects %q, got %q", moduleName, contract.declaredInputContentType, effectiveInputType)
		}
	}

	switch {
	case contract.hasDeclaredOutputContentType:
		outputType = contract.declaredOutputContentType
	case contract.hasOutput && contract.outputEncoding == dataEncodingUTF8 && contract.inputEncoding != dataEncodingUTF8:
		outputType = ""
	case contract.hasOutput:
		outputType = effectiveInputType
	}
	return effectiveInputType, outputType, nil
}

type moduleExecutionResult struct {
	output            contentData
	outputContentType string
	instantiation     time.Duration
	run               time.Duration
	total             time.Duration
	memoryBytes       uint64
	inputCapBytes     uint64
	outputCapBytes    uint64
}

func runModuleWithInput(ctx context.Context, runtime wazero.Runtime, compiled wazero.CompiledModule, inputBytes []byte, opts options, moduleName string) (output contentData, instantiation time.Duration, returnErr error) {
	exec, err := executeModuleWithInput(ctx, runtime, compiled, inputBytes, opts, moduleName, nil, "", opts.trustFirstStageContent)
	if err != nil {
		return contentData{}, 0, err
	}
	return exec.output, exec.instantiation, nil
}

func tryRunInteractiveModuleFirstFrame(baseCtx context.Context, spec ComponentInvocation, opts options, timeoutMS int) (bool, []byte, error) {
	body, err := readModulePath(spec.Source, opts)
	if err != nil {
		return false, nil, err
	}

	execCtx := baseCtx
	cancel := func() {}
	if timeoutMS > 0 {
		execCtx, cancel = wasmruntime.WithExecutionTimeout(baseCtx, time.Duration(timeoutMS)*time.Millisecond)
	}
	defer cancel()

	runtime := wasmruntime.New(execCtx)
	defer runtime.Close(baseCtx)

	compiled, err := runtime.CompileModule(execCtx, body)
	if err != nil {
		return false, nil, errors.New("Wasm module could not be compiled")
	}
	defer compiled.Close(baseCtx)

	mod, err := runtime.InstantiateModule(execCtx, compiled, wazero.NewModuleConfig().WithName("run-interactive-0"))
	if err != nil {
		return false, nil, errors.New("Wasm module could not be instantiated")
	}
	defer mod.Close(baseCtx)

	requiredFuncs := []string{
		"key_event",
		"pointer_event",
		"tick",
		"render",
		"render_width_px",
		"render_height_px",
	}
	for _, name := range requiredFuncs {
		if mod.ExportedFunction(name) == nil {
			return false, nil, nil
		}
	}
	if mod.Memory() == nil {
		return false, nil, nil
	}

	outputBytesValue, ok, err := getExportedValue(execCtx, mod, "output_rgba8_srgb_bytes")
	if err != nil {
		return false, nil, wasmruntime.HumanizeExecutionError(execCtx, err)
	}
	if !ok {
		return false, nil, nil
	}

	if err := applyModuleUniforms(execCtx, mod, spec.UniformValues); err != nil {
		return false, nil, err
	}

	renderWidthVal, _, err := getExportedValue(execCtx, mod, "render_width_px")
	if err != nil {
		return true, nil, wasmruntime.HumanizeExecutionError(execCtx, err)
	}
	renderHeightVal, _, err := getExportedValue(execCtx, mod, "render_height_px")
	if err != nil {
		return true, nil, wasmruntime.HumanizeExecutionError(execCtx, err)
	}
	renderWidth := int(int32(renderWidthVal))
	renderHeight := int(int32(renderHeightVal))
	if renderWidth <= 0 || renderHeight <= 0 {
		return true, nil, fmt.Errorf("%s: interactive module reported invalid render size %dx%d", spec.Source, renderWidth, renderHeight)
	}

	tickFunc := mod.ExportedFunction("tick")
	// Interactive snapshot contract: first tick is always tick(0).
	// Runtime hosts then pass monotonic elapsed milliseconds and schedule by returned next_wake_at_ms.
	if _, err := tickFunc.Call(execCtx, 0); err != nil {
		return true, nil, fmt.Errorf("%s: tick(0) failed: %w", spec.Source, wasmruntime.HumanizeExecutionError(execCtx, err))
	}
	renderFunc := mod.ExportedFunction("render")
	renderResult, err := renderFunc.Call(execCtx, 0)
	if err != nil {
		return true, nil, fmt.Errorf("%s: render(0) failed: %w", spec.Source, wasmruntime.HumanizeExecutionError(execCtx, err))
	}
	if len(renderResult) != 1 {
		return true, nil, fmt.Errorf("%s: render(0) returned %d values, want 1", spec.Source, len(renderResult))
	}

	outputLen := int(int32(renderResult[0]))
	expectedLen := renderWidth * renderHeight * 4
	if outputLen != expectedLen {
		return true, nil, fmt.Errorf("%s: render(0) returned %d bytes, expected %d (render_width_px*render_height_px*4)", spec.Source, outputLen, expectedLen)
	}

	outputBytes := int(int32(outputBytesValue))
	if outputBytes != expectedLen {
		return true, nil, fmt.Errorf("%s: output_rgba8_srgb_bytes returned %d bytes, expected %d (render_width_px*render_height_px*4)", spec.Source, outputBytes, expectedLen)
	}
	if outputLen != outputBytes {
		return true, nil, fmt.Errorf("%s: render(0) returned %d bytes, expected output_rgba8_srgb_bytes=%d", spec.Source, outputLen, outputBytes)
	}

	outputPtrValue, ok, err := getExportedValue(execCtx, mod, "output_ptr")
	if err != nil {
		return true, nil, wasmruntime.HumanizeExecutionError(execCtx, err)
	}
	if !ok {
		return true, nil, fmt.Errorf("%s: interactive module missing output_ptr export", spec.Source)
	}
	outputPtr := uint32(outputPtrValue)
	outputRaw, ok := mod.Memory().Read(outputPtr, uint32(outputLen))
	if !ok {
		return true, nil, fmt.Errorf("%s: could not read output frame", spec.Source)
	}
	rgbaBytes := slices.Clone(outputRaw)

	frame := image.NewRGBA(image.Rect(0, 0, renderWidth, renderHeight))
	copy(frame.Pix, rgbaBytes)
	bmp, err := encodeBMP(frame)
	if err != nil {
		return true, nil, fmt.Errorf("%s: could not encode first interactive frame as BMP: %w", spec.Source, err)
	}
	return true, bmp, nil
}

func executeModuleWithInput(
	ctx context.Context,
	runtime wazero.Runtime,
	compiled wazero.CompiledModule,
	inputBytes []byte,
	opts options,
	moduleName string,
	uniforms map[string]string,
	incomingContentType string,
	allowMissingInputContentType bool,
) (exec moduleExecutionResult, returnErr error) {
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

	if err := applyModuleUniforms(ctx, mod, uniforms); err != nil {
		returnErr = err
		return
	}

	contract, err := inspectRunModuleContract(ctx, mod)
	if err != nil {
		returnErr = err
		return
	}
	exec.inputCapBytes = contract.inputCapBytes
	exec.outputCapBytes = contract.outputCapBytes
	exec.output.encoding = contract.outputEncoding
	_, exec.outputContentType, err = resolveRunModuleContentType(contract, incomingContentType, allowMissingInputContentType, opts.contentTypeChecking, moduleName)
	if err != nil {
		returnErr = err
		return
	}

	inputPtr := contract.inputPtr
	inputCap := contract.inputCapBytes
	outputCap := uint32(contract.outputCapBytes)
	var outputPtr uint32
	runFunc := mod.ExportedFunction("render")

	var inputSize = uint64(len(inputBytes))
	if inputSize > inputCap {
		returnErr = fmt.Errorf("Input is too large (%d bytes > %d bytes input capacity)", inputSize, inputCap)
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
		returnErr = wasmruntime.HumanizeExecutionError(ctx, returnErr)
		return
	}

	outputCount := uint32(runResult[0])

	if outputCap > 0 {
		ptr, ok, err := getExportedValue(ctx, mod, "output_ptr")
		if err != nil {
			returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
			return
		}
		if !ok {
			returnErr = errors.New("Wasm module must export output_ptr() -> i32")
			return
		}
		outputPtr = uint32(ptr)

		if outputCount > outputCap {
			returnErr = errors.New("Module returned more bytes than its stated capacity")
			return
		}
		outputBytes, ok := mem.Read(outputPtr, outputCount)
		if !ok {
			returnErr = errors.New("Could not read output")
			return
		}
		// Copy out of wasm memory so callers can safely use the bytes after module close.
		exec.output.bytes = slices.Clone(outputBytes)
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
