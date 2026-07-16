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
	// Try global first
	if global := mod.ExportedGlobal(name); global != nil {
		return global.Get(), true, nil
	}

	// Try function if global doesn't exist
	if fn := mod.ExportedFunction(name); fn != nil {
		result, err := fn.Call(ctx)
		if err != nil {
			return 0, true, fmt.Errorf("%s() call failed: %w", name, err)
		}
		if len(result) != 1 {
			return 0, true, fmt.Errorf("%s() returned %d values, want 1", name, len(result))
		}
		return result[0], true, nil
	}

	return 0, false, nil
}

func normalizeIncomingContentType(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
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

func normalizeDeclaredContentType(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New("content type is empty")
	}
	if strings.Contains(value, ",") {
		return "", errors.New("content type must contain exactly one MIME type")
	}
	mediaType, params, err := mime.ParseMediaType(value)
	if err != nil {
		return "", fmt.Errorf("invalid content type %q: %w", value, err)
	}
	if mediaType == "" {
		return "", errors.New("content type is empty")
	}
	if len(params) > 0 {
		return "", fmt.Errorf("content type %q must not include parameters", value)
	}
	if strings.Contains(mediaType, "*") {
		return "", fmt.Errorf("content type %q must not include media ranges", value)
	}
	return strings.ToLower(mediaType), nil
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
	mediaType, err := normalizeDeclaredContentType(string(raw))
	if err != nil {
		return "", false, fmt.Errorf("invalid %s content type metadata: %w", prefix, err)
	}
	return mediaType, true, nil
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

	var input contentData
	// Get input_ptr and input_cap (required)
	inputPtr, ok, err := getExportedValue(ctx, mod, "input_ptr")
	if err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	}
	if !ok {
		returnErr = errors.New("Wasm module must export input_ptr as global or function")
		return
	}

	inputCap, ok, err := getExportedValue(ctx, mod, "input_utf8_cap")
	if err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	}
	if ok {
		input.encoding = dataEncodingUTF8
	} else if cap, ok, err := getExportedValue(ctx, mod, "input_bytes_cap"); err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	} else if ok {
		inputCap = cap
		input.encoding = dataEncodingRaw
	} else {
		returnErr = errors.New("Wasm module must export input_utf8_cap or input_bytes_cap as global or function")
		return
	}
	exec.inputCapBytes = inputCap

	var outputPtr, outputCap uint32
	if _, ok, err := getExportedValue(ctx, mod, "output_ptr"); err != nil {
		returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
		return
	} else if ok {
		if cap, ok, err := getExportedValue(ctx, mod, "output_utf8_cap"); err != nil {
			returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
			return
		} else if ok {
			outputCap = uint32(cap)
			exec.output.encoding = dataEncodingUTF8
		} else if cap, ok, err := getExportedValue(ctx, mod, "output_bytes_cap"); err != nil {
			returnErr = wasmruntime.HumanizeExecutionError(ctx, err)
			return
		} else if ok {
			outputCap = uint32(cap)
			exec.output.encoding = dataEncodingRaw
		} else {
			returnErr = errors.New("Wasm module must export output_utf8_cap or output_bytes_cap as global or function")
			return
		}
	}
	exec.outputCapBytes = uint64(outputCap)

	declaredInputContentType, hasDeclaredInputContentType, err := readOptionalModuleContentType(ctx, mod, "input")
	if err != nil {
		returnErr = err
		return
	}
	declaredOutputContentType, hasDeclaredOutputContentType, err := readOptionalModuleContentType(ctx, mod, "output")
	if err != nil {
		returnErr = err
		return
	}
	incomingContentType = normalizeIncomingContentType(incomingContentType)
	effectiveIncomingContentType := incomingContentType
	if effectiveIncomingContentType == "" && hasDeclaredInputContentType && allowMissingInputContentType {
		effectiveIncomingContentType = declaredInputContentType
	}

	if opts.contentTypeChecking == ContentTypeCheckingStrong && hasDeclaredInputContentType {
		if effectiveIncomingContentType == "" {
			if !allowMissingInputContentType {
				returnErr = fmt.Errorf("content type check failed for %s: module expects %q but pipeline content type is unspecified", moduleName, declaredInputContentType)
				return
			}
		} else if effectiveIncomingContentType != declaredInputContentType {
			returnErr = fmt.Errorf("content type check failed for %s: module expects %q, got %q", moduleName, declaredInputContentType, effectiveIncomingContentType)
			return
		}
	}

	switch {
	case hasDeclaredOutputContentType:
		exec.outputContentType = declaredOutputContentType
	case exec.output.encoding == dataEncodingUTF8 && input.encoding != dataEncodingUTF8:
		// A bytes-in, UTF-8-out component produces new text; the incoming
		// (binary) pipeline content type does not describe its output.
		exec.outputContentType = ""
	case exec.output.encoding == dataEncodingUTF8 || exec.output.encoding == dataEncodingRaw:
		exec.outputContentType = effectiveIncomingContentType
	default:
		exec.outputContentType = ""
	}

	runFunc := mod.ExportedFunction("render")
	if runFunc == nil {
		returnErr = errors.New("Wasm module must export render(i32) -> i32")
		return
	}

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
			returnErr = errors.New("Wasm module must export output_ptr as global or function")
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
