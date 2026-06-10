package qinternal

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

const ReservedRecipesDir = "_recipes"
const ReservedFormsDir = "_forms"
const ReservedComponentsDir = "_components"

func IsReservedRouterDirectoryName(name string) bool {
	switch name {
	case ReservedRecipesDir, ReservedFormsDir, ReservedComponentsDir:
		return true
	default:
		return false
	}
}

func IsReservedRouterRelPath(relPath string) bool {
	relPath = strings.TrimPrefix(relPath, "/")
	first, _, _ := strings.Cut(relPath, "/")
	return IsReservedRouterDirectoryName(first)
}

type RouterProjectConfig struct {
	ContentRoot string

	RecipesRoot    string
	FormsRoot      string
	ComponentsRoot string
}

func ResolveRouterProjectConfig(config RouterProjectConfig) (RouterProjectConfig, error) {
	var err error
	if config.RecipesRoot == "" {
		config.RecipesRoot, err = discoverOptionalProjectDir(config.ContentRoot, ReservedRecipesDir, "recipes")
		if err != nil {
			return RouterProjectConfig{}, err
		}
	}
	if config.FormsRoot == "" {
		config.FormsRoot, err = discoverOptionalProjectDir(config.ContentRoot, ReservedFormsDir, "forms")
		if err != nil {
			return RouterProjectConfig{}, err
		}
	}
	if config.ComponentsRoot == "" {
		config.ComponentsRoot, err = discoverOptionalProjectDir(config.ContentRoot, ReservedComponentsDir, "components")
		if err != nil {
			return RouterProjectConfig{}, err
		}
	}
	return config, nil
}

func discoverOptionalProjectDir(contentRoot string, dirName string, label string) (string, error) {
	if contentRoot == "" || dirName == "" {
		return "", nil
	}
	candidate := filepath.Join(contentRoot, dirName)
	info, err := os.Stat(candidate)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("Invalid %s directory: %v", label, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("Invalid %s directory: %q is not a directory", label, candidate)
	}
	return candidate, nil
}

func IsDevHardRefreshRequest(r *http.Request) bool {
	if r == nil {
		return false
	}
	cacheControl := strings.ToLower(r.Header.Get("Cache-Control"))
	pragma := strings.ToLower(r.Header.Get("Pragma"))
	hasHardReloadCacheHint := strings.Contains(cacheControl, "no-cache") || strings.Contains(cacheControl, "max-age=0") || strings.Contains(pragma, "no-cache")
	if !hasHardReloadCacheHint {
		return false
	}

	dest := strings.ToLower(r.Header.Get("Sec-Fetch-Dest"))
	if dest == "document" {
		return true
	}
	if dest != "" && dest != "empty" {
		return false
	}

	accept := strings.ToLower(r.Header.Get("Accept"))
	return strings.Contains(accept, "text/html")
}

func ValidateOptionalDirectory(label string, dir string) error {
	if dir == "" {
		return nil
	}
	info, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("Invalid %s directory: %v", label, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("Invalid %s directory: %q is not a directory", label, dir)
	}
	return nil
}
