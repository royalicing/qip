package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasminspect"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
)

func readModulePath(path string, opts options) ([]byte, error) {
	body, err := resolveModuleSource(path, opts)
	if err != nil {
		return nil, err
	}
	if err := logAndValidateModule(path, body, opts); err != nil {
		return nil, err
	}
	return body, nil
}

func resolveModuleSource(path string, opts options) ([]byte, error) {
	return resolveModuleSourceWithUniforms(path, opts, nil)
}

func resolveModuleSourceWithUniforms(path string, opts options, uniforms map[string]string) ([]byte, error) {
	if len(opts.hosts) == 0 || strings.HasPrefix(path, "https://") {
		return readModuleSource(path)
	}
	return qinternal.ResolveComponentSource(context.Background(), path, opts.hosts, func(body []byte, label string) error {
		return validateRunnableModuleCandidate(body, label, opts, uniforms)
	})
}

var canonicalWasmHeader = []byte{0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00}

func validateMultipartWasmHeader(body []byte, label string) error {
	if len(body) < len(canonicalWasmHeader) || !bytes.Equal(body[:len(canonicalWasmHeader)], canonicalWasmHeader) {
		return fmt.Errorf("%s does not have a WebAssembly 1.0 header", label)
	}
	return nil
}

func resolveMultipartFormFile(path string, hosts []qinternal.ComponentHost) ([]byte, error) {
	body, err := os.ReadFile(path)
	if err == nil {
		return body, nil
	}
	if !errors.Is(err, os.ErrNotExist) || len(hosts) == 0 || !qinternal.RemotelyEligibleComponentPath(path) {
		return nil, err
	}
	return qinternal.ResolveComponentSource(context.Background(), path, hosts, validateMultipartWasmHeader)
}

func validateRunnableModuleCandidate(body []byte, label string, opts options, uniforms map[string]string) error {
	if err := logAndValidateModule(label, body, opts); err != nil {
		return err
	}
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)
	compiled, err := runtime.CompileModule(ctx, body)
	if err != nil {
		return fmt.Errorf("Wasm module %q could not be compiled: %w", label, err)
	}
	defer compiled.Close(ctx)
	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName("host-source-validation"))
	if err != nil {
		return fmt.Errorf("Wasm module %q could not be instantiated: %w", label, err)
	}
	defer mod.Close(ctx)
	if err := applyModuleUniforms(ctx, mod, uniforms); err != nil {
		return err
	}
	if mod.ExportedFunction("tile_rgba32float_64x64") != nil {
		stage, err := loadTileStage(ctx, mod)
		if err != nil {
			return err
		}
		_ = stage
		return nil
	}
	if _, err := inspectRunModuleContract(ctx, mod); err != nil {
		return fmt.Errorf("%s: %w", label, err)
	}
	return nil
}

func readModuleSource(path string) ([]byte, error) {
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

	return body, nil
}

func logAndValidateModule(path string, body []byte, opts options) error {
	if opts.verbose {
		moduleDigest := sha256.Sum256(body)
		vlogf(opts, "module %s sha256: %x", path, moduleDigest)
	}
	if err := validateModulePolicy(path, body, opts.modulePolicy); err != nil {
		return err
	}
	return nil
}

func validateModulePolicy(path string, body []byte, policy wasminspect.ModulePolicy) error {
	if err := wasminspect.ValidateModulePolicy(body, policy); err != nil {
		return fmt.Errorf("Wasm module %q rejected by policy: %w", path, err)
	}
	return nil
}
