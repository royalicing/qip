package main

import (
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

func walkFilesFollowingSymlinks(root string, entryKind string, visit func(fullPath string, info fs.FileInfo) error) error {
	seenDirs := make(map[string]uint8)
	var walkDir func(readDir string) error
	walkDir = func(readDir string) error {
		realDir, err := filepath.EvalSymlinks(readDir)
		if err != nil {
			return err
		}
		realDir, err = filepath.Abs(realDir)
		if err != nil {
			return err
		}
		realDir = filepath.Clean(realDir)
		if seenDirs[realDir] > 0 {
			// Avoid infinite recursion when a symlink points back to an ancestor.
			return nil
		}
		seenDirs[realDir]++
		defer func() {
			seenDirs[realDir]--
		}()

		entries, err := os.ReadDir(readDir)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			fullPath := filepath.Join(readDir, entry.Name())
			mode := entry.Type()
			if mode.IsRegular() {
				info, err := entry.Info()
				if err != nil {
					return err
				}
				if err := visit(fullPath, info); err != nil {
					return err
				}
				continue
			}
			if mode.IsDir() {
				if err := walkDir(fullPath); err != nil {
					return err
				}
				continue
			}
			if mode&fs.ModeSymlink == 0 {
				return fmt.Errorf("%s entry %q must be a regular file", entryKind, fullPath)
			}

			targetInfo, err := os.Stat(fullPath)
			if err != nil {
				return err
			}
			if targetInfo.Mode().IsRegular() {
				if err := visit(fullPath, targetInfo); err != nil {
					return err
				}
				continue
			}
			if targetInfo.IsDir() {
				if err := walkDir(fullPath); err != nil {
					return err
				}
				continue
			}
			return fmt.Errorf("%s entry %q must be a regular file", entryKind, fullPath)
		}
		return nil
	}

	return walkDir(root)
}

func loadComponentAssets(componentsRoot string) (map[string]componentAsset, []string, error) {
	assets := make(map[string]componentAsset)
	if componentsRoot == "" {
		return assets, nil, nil
	}

	err := walkFilesFollowingSymlinks(componentsRoot, "component", func(fullPath string, _ fs.FileInfo) error {
		relPath, err := filepath.Rel(componentsRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if !utf8.ValidString(relPath) {
			return fmt.Errorf("component path %q must be valid UTF-8", relPath)
		}
		if strings.HasPrefix(relPath, "/") {
			return fmt.Errorf("component path %q must not start with /", relPath)
		}
		cleanRel := path.Clean(relPath)
		if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
			return fmt.Errorf("component path %q is not canonical", relPath)
		}
		if strings.ToLower(path.Ext(relPath)) != ".wasm" {
			return nil
		}

		body, err := os.ReadFile(fullPath)
		if err != nil {
			return err
		}
		requestPath := "/" + cleanRel
		if _, exists := assets[requestPath]; exists {
			return fmt.Errorf("duplicate component request path %q", requestPath)
		}
		assets[requestPath] = componentAsset{
			body:        body,
			contentType: "application/wasm",
		}
		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	requestPaths := make([]string, 0, len(assets))
	for requestPath := range assets {
		requestPaths = append(requestPaths, requestPath)
	}
	sort.Strings(requestPaths)
	return assets, requestPaths, nil
}

func loadElementAssets(elementsRoot string) (map[string]elementAsset, []string, []string, error) {
	assets := make(map[string]elementAsset)
	if elementsRoot == "" {
		return assets, nil, nil, nil
	}

	err := walkFilesFollowingSymlinks(elementsRoot, "element", func(fullPath string, _ fs.FileInfo) error {
		relPath, err := filepath.Rel(elementsRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if !utf8.ValidString(relPath) {
			return fmt.Errorf("element path %q must be valid UTF-8", relPath)
		}
		if strings.HasPrefix(relPath, "/") {
			return fmt.Errorf("element path %q must not start with /", relPath)
		}
		cleanRel := path.Clean(relPath)
		if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
			return fmt.Errorf("element path %q is not canonical", relPath)
		}
		if strings.ToLower(path.Ext(relPath)) != ".js" {
			return nil
		}

		requestPath := "/elements/" + cleanRel
		if _, exists := assets[requestPath]; exists {
			return fmt.Errorf("duplicate element request path %q", requestPath)
		}
		assets[requestPath] = elementAsset{filePath: fullPath}
		return nil
	})
	if err != nil {
		return nil, nil, nil, err
	}

	requestPaths := make([]string, 0, len(assets))
	entryPaths := make([]string, 0, len(assets))
	for requestPath := range assets {
		requestPaths = append(requestPaths, requestPath)
		rel := strings.TrimPrefix(requestPath, "/elements/")
		if !strings.Contains(rel, "/") && isValidCustomElementName(strings.TrimSuffix(rel, ".js")) {
			entryPaths = append(entryPaths, requestPath)
		}
	}
	sort.Strings(requestPaths)
	sort.Strings(entryPaths)
	return assets, requestPaths, entryPaths, nil
}

func isValidCustomElementName(name string) bool {
	if name == "" || !strings.Contains(name, "-") || strings.HasPrefix(strings.ToLower(name), "xml") {
		return false
	}
	for _, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-' {
			continue
		}
		return false
	}
	return true
}
