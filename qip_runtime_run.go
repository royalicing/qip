package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
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
	hasCommit                    bool
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

	if commitFunc := mod.ExportedFunction("commit"); commitFunc != nil {
		params := commitFunc.Definition().ParamTypes()
		results := commitFunc.Definition().ResultTypes()
		if len(params) != 0 || len(results) != 1 || results[0] != api.ValueTypeI64 {
			return contract, errors.New("Wasm module commit export must have signature commit() -> i64")
		}
		contract.hasCommit = true
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

type contentRenderTrapError struct {
	cause error
}

func (e *contentRenderTrapError) Error() string {
	return fmt.Sprintf("render trapped: %v", e.cause)
}

func (e *contentRenderTrapError) Unwrap() error {
	return e.cause
}

func runModuleWithInput(ctx context.Context, runtime wazero.Runtime, compiled wazero.CompiledModule, inputBytes []byte, opts options, moduleName string) (output contentData, instantiation time.Duration, returnErr error) {
	exec, err := executeModuleWithInput(ctx, runtime, compiled, inputBytes, opts, moduleName, nil, "", opts.trustFirstStageContent)
	if err != nil {
		return contentData{}, 0, err
	}
	return exec.output, exec.instantiation, nil
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
		returnErr = fmt.Errorf("input is too large (%d bytes > %d bytes input capacity)", inputSize, inputCap)
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
		returnErr = &contentRenderTrapError{cause: wasmruntime.HumanizeExecutionError(ctx, returnErr)}
		return
	}
	if contract.hasCommit {
		commitResult, err := mod.ExportedFunction("commit").Call(ctx)
		if err != nil {
			returnErr = fmt.Errorf("commit trapped; the Content contract requires commit() not to trap: %w", wasmruntime.HumanizeExecutionError(ctx, err))
			return
		}
		if result := int64(commitResult[0]); result < 0 {
			bits := uint64(result)
			if bits&(uint64(1)<<62) != 0 {
				returnErr = fmt.Errorf("rejected invalid input at byte %d (commit returned %d)", uint32(bits), result)
			} else {
				returnErr = fmt.Errorf("rejected input (commit returned %d)", result)
			}
			return
		}
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
