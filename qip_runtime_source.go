package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/royalicing/qip/internal/wasminspect"
)

func readModulePath(path string, opts options) ([]byte, error) {
	body, err := readModuleSource(path)
	if err != nil {
		return nil, err
	}
	if err := logAndValidateModule(path, body, opts); err != nil {
		return nil, err
	}
	return body, nil
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
