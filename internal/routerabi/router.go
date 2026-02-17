package routerabi

import (
	"context"
	"fmt"
	"math"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

type Router struct {
	runtime  wazero.Runtime
	compiled wazero.CompiledModule
}

type RouteResult struct {
	Status        int
	ETag          string
	ContentType   string
	ContentSHA256 [][32]byte
	RecipeSHA256  [][32]byte
	Location      string
}

func Load(ctx context.Context, wasm []byte) (*Router, error) {
	if len(wasm) == 0 {
		return nil, fmt.Errorf("%w: empty wasm", ErrRouterInternal)
	}

	runtime := wazero.NewRuntime(ctx)
	compiled, err := runtime.CompileModule(ctx, wasm)
	if err != nil {
		_ = runtime.Close(ctx)
		return nil, fmt.Errorf("%w: compile failed", ErrRouterInternal)
	}

	if err := validateCompiledExportsV0(compiled); err != nil {
		_ = compiled.Close(ctx)
		_ = runtime.Close(ctx)
		return nil, err
	}

	mod, err := runtime.InstantiateModule(ctx, compiled, newModuleConfig())
	if err != nil {
		_ = compiled.Close(ctx)
		_ = runtime.Close(ctx)
		return nil, fmt.Errorf("%w: instantiate failed", ErrRouterInternal)
	}
	_ = mod.Close(ctx)

	return &Router{
		runtime:  runtime,
		compiled: compiled,
	}, nil
}

func (r *Router) Close(ctx context.Context) error {
	if r == nil || r.runtime == nil {
		return nil
	}
	err := r.runtime.Close(ctx)
	r.runtime = nil
	r.compiled = nil
	return err
}

func (r *Router) Route(ctx context.Context, path, query string) (RouteResult, error) {
	if r == nil || r.runtime == nil || r.compiled == nil {
		return RouteResult{}, fmt.Errorf("%w: router is not loaded", ErrRouterInternal)
	}

	mod, err := r.runtime.InstantiateModule(ctx, r.compiled, newModuleConfig())
	if err != nil {
		return RouteResult{}, fmt.Errorf("%w: instantiate failed", ErrRouterInternal)
	}
	defer mod.Close(ctx)

	mem := mod.ExportedMemory(ExportMemory)
	if mem == nil {
		return RouteResult{}, missingExportError(ExportMemory)
	}

	pathBytes := []byte(path)
	queryBytes := []byte(query)
	if len(pathBytes) > math.MaxInt32 || len(queryBytes) > math.MaxInt32 {
		return RouteResult{}, fmt.Errorf("%w: path/query length exceeds i32", ErrInputTooLarge)
	}
	pathLen := int32(len(pathBytes))
	queryLen := int32(len(queryBytes))

	inputPtr, err := callI32NoArgs(ctx, mod, ExportInputPtr)
	if err != nil {
		return RouteResult{}, err
	}
	inputCap, err := callI32NoArgs(ctx, mod, ExportInputCap)
	if err != nil {
		return RouteResult{}, err
	}
	if inputCap < 0 {
		return RouteResult{}, fmt.Errorf("%w: input_cap=%d", ErrOutOfBounds, inputCap)
	}

	inputLen := len(pathBytes) + len(queryBytes)
	if inputLen > int(inputCap) {
		return RouteResult{}, fmt.Errorf("%w: input=%d cap=%d", ErrInputTooLarge, inputLen, inputCap)
	}

	input := make([]byte, 0, inputLen)
	input = append(input, pathBytes...)
	input = append(input, queryBytes...)

	if err := validateRegionU64(memorySizeBytes(mem), inputPtr, uint64(len(input)), "input"); err != nil {
		return RouteResult{}, err
	}
	if len(input) > 0 && !mem.Write(uint32(inputPtr), input) {
		return RouteResult{}, fmt.Errorf("%w: input write failed", ErrOutOfBounds)
	}

	status, err := callRoute(ctx, mod, pathLen, queryLen)
	if err != nil {
		return RouteResult{}, err
	}

	view, err := readRouteResultView(ctx, mod, status)
	if err != nil {
		return RouteResult{}, err
	}
	if err := validateRouteResultV0(memorySizeBytes(mem), view); err != nil {
		return RouteResult{}, err
	}

	etag, err := readString(mem, view.ETagPtr, view.ETagLen)
	if err != nil {
		return RouteResult{}, err
	}
	contentType, err := readString(mem, view.ContentTypePtr, view.ContentTypeLen)
	if err != nil {
		return RouteResult{}, err
	}
	contentDigests, err := readDigestArray(mem, view.ContentSHA256Ptr, view.ContentSHA256Count)
	if err != nil {
		return RouteResult{}, err
	}
	recipeDigests, err := readDigestArray(mem, view.RecipeSHA256Ptr, view.RecipeSHA256Count)
	if err != nil {
		return RouteResult{}, err
	}
	location, err := readString(mem, view.LocationPtr, view.LocationLen)
	if err != nil {
		return RouteResult{}, err
	}

	return RouteResult{
		Status:        int(view.Status),
		ETag:          etag,
		ContentType:   contentType,
		ContentSHA256: contentDigests,
		RecipeSHA256:  recipeDigests,
		Location:      location,
	}, nil
}

func validateCompiledExportsV0(compiled wazero.CompiledModule) error {
	if _, ok := compiled.ExportedMemories()[ExportMemory]; !ok {
		return missingExportError(ExportMemory)
	}

	funcs := compiled.ExportedFunctions()
	for name, sig := range requiredFunctionSignaturesV0() {
		def, ok := funcs[name]
		if !ok {
			return missingExportError(name)
		}
		if !signatureMatches(def.ParamTypes(), sig.params) || !signatureMatches(def.ResultTypes(), sig.results) {
			return fmt.Errorf("%w: %s invalid signature want %s got %s", ErrMissingExport, name, formatSignature(sig.params, sig.results), formatSignature(def.ParamTypes(), def.ResultTypes()))
		}
	}

	return nil
}

func newModuleConfig() wazero.ModuleConfig {
	return wazero.NewModuleConfig().WithName("").WithStartFunctions()
}

func callRoute(ctx context.Context, mod api.Module, pathLen, queryLen int32) (int32, error) {
	fn := mod.ExportedFunction(ExportRoute)
	if fn == nil {
		return 0, missingExportError(ExportRoute)
	}
	result, err := fn.Call(ctx, api.EncodeI32(pathLen), api.EncodeI32(queryLen))
	if err != nil {
		return 0, fmt.Errorf("%w: route call failed", ErrRouterInternal)
	}
	if len(result) != 1 {
		return 0, fmt.Errorf("%w: route returned %d values", ErrRouterInternal, len(result))
	}
	status := api.DecodeI32(result[0])
	if status < 0 {
		return 0, fmt.Errorf("%w: negative route status=%d", ErrRouterInternal, status)
	}
	return status, nil
}

func callI32NoArgs(ctx context.Context, mod api.Module, name string) (int32, error) {
	fn := mod.ExportedFunction(name)
	if fn == nil {
		return 0, missingExportError(name)
	}
	result, err := fn.Call(ctx)
	if err != nil {
		return 0, fmt.Errorf("%w: %s call failed", ErrRouterInternal, name)
	}
	if len(result) != 1 {
		return 0, fmt.Errorf("%w: %s returned %d values", ErrRouterInternal, name, len(result))
	}
	return api.DecodeI32(result[0]), nil
}

func readRouteResultView(ctx context.Context, mod api.Module, status int32) (routeResultViewV0, error) {
	etagPtr, err := callI32NoArgs(ctx, mod, ExportETagPtr)
	if err != nil {
		return routeResultViewV0{}, err
	}
	etagLen, err := callI32NoArgs(ctx, mod, ExportETagLen)
	if err != nil {
		return routeResultViewV0{}, err
	}
	contentTypePtr, err := callI32NoArgs(ctx, mod, ExportContentTypePtr)
	if err != nil {
		return routeResultViewV0{}, err
	}
	contentTypeLen, err := callI32NoArgs(ctx, mod, ExportContentTypeLen)
	if err != nil {
		return routeResultViewV0{}, err
	}
	contentSHA256Ptr, err := callI32NoArgs(ctx, mod, ExportContentSHA256Ptr)
	if err != nil {
		return routeResultViewV0{}, err
	}
	contentSHA256Count, err := callI32NoArgs(ctx, mod, ExportContentSHA256Count)
	if err != nil {
		return routeResultViewV0{}, err
	}
	recipeSHA256Ptr, err := callI32NoArgs(ctx, mod, ExportRecipeSHA256Ptr)
	if err != nil {
		return routeResultViewV0{}, err
	}
	recipeSHA256Count, err := callI32NoArgs(ctx, mod, ExportRecipeSHA256Count)
	if err != nil {
		return routeResultViewV0{}, err
	}
	locationPtr, err := callI32NoArgs(ctx, mod, ExportLocationPtr)
	if err != nil {
		return routeResultViewV0{}, err
	}
	locationLen, err := callI32NoArgs(ctx, mod, ExportLocationLen)
	if err != nil {
		return routeResultViewV0{}, err
	}

	return routeResultViewV0{
		Status:             status,
		ETagPtr:            etagPtr,
		ETagLen:            etagLen,
		ContentTypePtr:     contentTypePtr,
		ContentTypeLen:     contentTypeLen,
		ContentSHA256Ptr:   contentSHA256Ptr,
		ContentSHA256Count: contentSHA256Count,
		RecipeSHA256Ptr:    recipeSHA256Ptr,
		RecipeSHA256Count:  recipeSHA256Count,
		LocationPtr:        locationPtr,
		LocationLen:        locationLen,
	}, nil
}

func readString(mem api.Memory, ptr, length int32) (string, error) {
	if length == 0 {
		return "", nil
	}
	data, ok := mem.Read(uint32(ptr), uint32(length))
	if !ok {
		return "", fmt.Errorf("%w: could not read string ptr=%d len=%d", ErrOutOfBounds, ptr, length)
	}
	clone := append([]byte(nil), data...)
	return string(clone), nil
}

func readDigestArray(mem api.Memory, ptr, count int32) ([][32]byte, error) {
	if count < 0 {
		return nil, fmt.Errorf("%w: count=%d", ErrInvalidDigestCount, count)
	}
	if count == 0 {
		return [][32]byte{}, nil
	}

	byteLen := uint64(count) * SHA256DigestBytes
	if byteLen > math.MaxUint32 {
		return nil, fmt.Errorf("%w: digest bytes too large count=%d", ErrOutOfBounds, count)
	}

	data, ok := mem.Read(uint32(ptr), uint32(byteLen))
	if !ok {
		return nil, fmt.Errorf("%w: could not read digest array ptr=%d count=%d", ErrOutOfBounds, ptr, count)
	}

	out := make([][32]byte, count)
	for i := range out {
		start := i * int(SHA256DigestBytes)
		copy(out[i][:], data[start:start+int(SHA256DigestBytes)])
	}
	return out, nil
}

func memorySizeBytes(mem api.Memory) uint32 {
	size := mem.Size()
	if size != 0 {
		return size
	}

	pages, ok := mem.Grow(0)
	if !ok {
		return 0
	}
	return pages * 65536
}

type functionSignature struct {
	params  []api.ValueType
	results []api.ValueType
}

func requiredFunctionSignaturesV0() map[string]functionSignature {
	i32 := api.ValueTypeI32
	noArgsOneI32 := functionSignature{
		params:  []api.ValueType{},
		results: []api.ValueType{i32},
	}

	return map[string]functionSignature{
		ExportInputPtr:           noArgsOneI32,
		ExportInputCap:           noArgsOneI32,
		ExportETagPtr:            noArgsOneI32,
		ExportETagLen:            noArgsOneI32,
		ExportContentTypePtr:     noArgsOneI32,
		ExportContentTypeLen:     noArgsOneI32,
		ExportContentSHA256Ptr:   noArgsOneI32,
		ExportContentSHA256Count: noArgsOneI32,
		ExportRecipeSHA256Ptr:    noArgsOneI32,
		ExportRecipeSHA256Count:  noArgsOneI32,
		ExportLocationPtr:        noArgsOneI32,
		ExportLocationLen:        noArgsOneI32,
		ExportRoute: {
			params:  []api.ValueType{i32, i32},
			results: []api.ValueType{i32},
		},
	}
}

func signatureMatches(actual, expected []api.ValueType) bool {
	if len(actual) != len(expected) {
		return false
	}
	for i := range actual {
		if actual[i] != expected[i] {
			return false
		}
	}
	return true
}

func formatSignature(params, results []api.ValueType) string {
	return fmt.Sprintf("(%s)->(%s)", formatTypes(params), formatTypes(results))
}

func formatTypes(types []api.ValueType) string {
	if len(types) == 0 {
		return ""
	}
	out := ""
	for i, t := range types {
		if i > 0 {
			out += ","
		}
		if t == api.ValueTypeI32 {
			out += "i32"
		} else if t == api.ValueTypeI64 {
			out += "i64"
		} else if t == api.ValueTypeF32 {
			out += "f32"
		} else if t == api.ValueTypeF64 {
			out += "f64"
		} else {
			out += fmt.Sprintf("0x%x", byte(t))
		}
	}
	return out
}
