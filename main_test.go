package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseRecipeFilename(t *testing.T) {
	t.Run("active", func(t *testing.T) {
		order, disabled, err := parseRecipeFilename("10-markdown.wasm")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if disabled {
			t.Fatalf("expected active recipe")
		}
		if order != 10 {
			t.Fatalf("order=%d, want 10", order)
		}
	})

	t.Run("disabled", func(t *testing.T) {
		order, disabled, err := parseRecipeFilename("-99-wrap.wasm")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !disabled {
			t.Fatalf("expected disabled recipe")
		}
		if order != 99 {
			t.Fatalf("order=%d, want 99", order)
		}
	})

	t.Run("invalid", func(t *testing.T) {
		cases := []string{
			"10-markdown.wat",
			"a0-markdown.wasm",
			"10.wasm",
			"10-.wasm",
			"10-rendér.wasm",
		}
		for _, filename := range cases {
			if _, _, err := parseRecipeFilename(filename); err == nil {
				t.Fatalf("expected error for %q", filename)
			}
		}
	})
}

func TestContentRequestPaths(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{
			name: "html index",
			in:   "index.html",
			want: []string{"/index.html", "/"},
		},
		{
			name: "nested html index",
			in:   "docs/index.html",
			want: []string{"/docs/index.html", "/docs", "/docs/"},
		},
		{
			name: "markdown page",
			in:   "guide/start.md",
			want: []string{"/guide/start.md", "/guide/start"},
		},
		{
			name: "binary asset",
			in:   "images/logo.png",
			want: []string{"/images/logo.png"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := contentRequestPaths(tc.in)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("paths=%v, want %v", got, tc.want)
			}
		})
	}
}

func TestResolveDevContentRoute(t *testing.T) {
	routes := map[string]devContentRoute{
		"/docs":  {filePath: "docs/index.md", sourceMIME: "text/markdown"},
		"/docs/": {filePath: "docs/index.md", sourceMIME: "text/markdown"},
	}

	if _, ok := resolveDevContentRoute(routes, "/docs"); !ok {
		t.Fatal("expected /docs to resolve")
	}
	if _, ok := resolveDevContentRoute(routes, "/docs/"); !ok {
		t.Fatal("expected /docs/ to resolve")
	}
	if _, ok := resolveDevContentRoute(routes, "/missing"); ok {
		t.Fatal("expected /missing to be unresolved")
	}
}

func TestNormalizeDevArgs(t *testing.T) {
	t.Run("content first", func(t *testing.T) {
		in := []string{"docs/", "--recipes", "recipes/", "-p", "4004"}
		got := normalizeDevArgs(in)
		want := []string{"--recipes", "recipes/", "-p", "4004", "docs/"}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("args=%v, want %v", got, want)
		}
	})

	t.Run("flags first unchanged", func(t *testing.T) {
		in := []string{"--recipes", "recipes/", "-p", "4004", "docs/"}
		got := normalizeDevArgs(in)
		if !reflect.DeepEqual(got, in) {
			t.Fatalf("args=%v, want %v", got, in)
		}
	})
}

func TestLoadRecipeChainsIgnoresNonWasm(t *testing.T) {
	root := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	// Non-wasm source files may live beside compiled recipes.
	if err := os.WriteFile(filepath.Join(recipeDir, "10-markdown-basic.zig"), []byte("const x = 1;"), 0o644); err != nil {
		t.Fatalf("write source: %v", err)
	}

	wasmBytes, err := os.ReadFile(filepath.Join("examples", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "10-markdown-basic.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write wasm: %v", err)
	}

	chains, digests, err := loadRecipeChains(context.Background(), root, options{})
	if err != nil {
		t.Fatalf("loadRecipeChains error: %v", err)
	}
	t.Cleanup(func() {
		closeModuleChains(context.Background(), chains)
	})

	chain, ok := chains["text/markdown"]
	if !ok || chain == nil {
		t.Fatalf("expected text/markdown chain")
	}
	if got := len(digests["text/markdown"]); got != 1 {
		t.Fatalf("digest count=%d, want 1", got)
	}
}

func TestLoadRecipeChainsRejectsInvalidFilename(t *testing.T) {
	root := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmBytes, err := os.ReadFile(filepath.Join("examples", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "a0-invalid.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write wasm: %v", err)
	}

	if _, _, err := loadRecipeChains(context.Background(), root, options{}); err == nil {
		t.Fatal("expected error for invalid recipe filename")
	}
}

func TestLoadRecipeChainsRejectsDuplicatePrefix(t *testing.T) {
	root := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmBytes, err := os.ReadFile(filepath.Join("examples", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "42-a.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write wasm a: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "42-b.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write wasm b: %v", err)
	}

	if _, _, err := loadRecipeChains(context.Background(), root, options{}); err == nil {
		t.Fatal("expected error for duplicate recipe prefix")
	}
}

func TestParseImageModuleSpecs(t *testing.T) {
	t.Run("module with query", func(t *testing.T) {
		specs, err := parseImageModuleSpecs([]string{
			"examples/rgba/color-halftone.wasm",
			"?max_radius=2.0",
			"examples/rgba/brightness.wasm",
			"?brightness=0.2",
		})
		if err != nil {
			t.Fatalf("parseImageModuleSpecs error: %v", err)
		}
		if len(specs) != 2 {
			t.Fatalf("spec count=%d, want 2", len(specs))
		}
		if specs[0].path != "examples/rgba/color-halftone.wasm" {
			t.Fatalf("spec[0].path=%q", specs[0].path)
		}
		if got := specs[0].uniforms["max_radius"]; got != "2.0" {
			t.Fatalf("spec[0] max_radius=%q, want 2.0", got)
		}
		if specs[1].path != "examples/rgba/brightness.wasm" {
			t.Fatalf("spec[1].path=%q", specs[1].path)
		}
		if got := specs[1].uniforms["brightness"]; got != "0.2" {
			t.Fatalf("spec[1] brightness=%q, want 0.2", got)
		}
	})

	t.Run("query before module is error", func(t *testing.T) {
		if _, err := parseImageModuleSpecs([]string{"?max_radius=2.0"}); err == nil {
			t.Fatal("expected error for query before module")
		}
	})

	t.Run("empty query is error", func(t *testing.T) {
		if _, err := parseImageModuleSpecs([]string{"examples/rgba/brightness.wasm", "?"}); err == nil {
			t.Fatal("expected error for empty query")
		}
	})
}

func TestLoadFormModules(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "nested"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmBytes, err := os.ReadFile(filepath.Join("examples", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "contact.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write contact wasm: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "nested", "signup.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write nested wasm: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "README.txt"), []byte("ignore"), 0o644); err != nil {
		t.Fatalf("write non-wasm: %v", err)
	}

	modules, digests, err := loadFormModules(root)
	if err != nil {
		t.Fatalf("loadFormModules error: %v", err)
	}
	if len(modules) != 2 {
		t.Fatalf("module count=%d, want 2", len(modules))
	}
	if len(digests) != 2 {
		t.Fatalf("digest count=%d, want 2", len(digests))
	}
	if !bytes.Equal(modules["contact"], wasmBytes) {
		t.Fatalf("contact module bytes mismatch")
	}
	if !bytes.Equal(modules["nested/signup"], wasmBytes) {
		t.Fatalf("nested/signup module bytes mismatch")
	}
	wantDigest := sha256.Sum256(wasmBytes)
	if got := digests["contact"]; got != wantDigest {
		t.Fatalf("contact digest mismatch")
	}
}

func TestExtractQIPFormNames(t *testing.T) {
	htmlBody := []byte(`<html><body><qip-form name="contact"></qip-form><qip-form name='nested/signup'></qip-form><qip-form name="contact"></qip-form></body></html>`)
	names, err := extractQIPFormNames(htmlBody)
	if err != nil {
		t.Fatalf("extractQIPFormNames error: %v", err)
	}
	want := []string{"contact", "nested/signup"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("names=%v, want %v", names, want)
	}
}

func TestInjectQIPFormRuntime(t *testing.T) {
	htmlBody := []byte(`<html><body><h1>Page</h1><qip-form name="contact"></qip-form></body></html>`)
	formModules := map[string][]byte{
		"contact": []byte{0x00, 0x61, 0x73, 0x6d},
	}
	formDigests := map[string][32]byte{
		"contact": sha256.Sum256(formModules["contact"]),
	}

	out, digests, err := injectQIPFormRuntime(htmlBody, formModules, formDigests)
	if err != nil {
		t.Fatalf("injectQIPFormRuntime error: %v", err)
	}
	if len(digests) != 1 || digests[0] != formDigests["contact"] {
		t.Fatalf("unexpected digest list: %v", digests)
	}
	if !bytes.Contains(out, []byte(`<script type="module">`)) {
		t.Fatalf("expected inline module script injection")
	}
	if !bytes.Contains(out, []byte(`customElements.define("qip-form"`)) {
		t.Fatalf("expected qip-form custom element runtime")
	}
	if !strings.Contains(string(out), `["contact",`) {
		t.Fatalf("expected contact module lookup entry")
	}

	scriptIdx := strings.Index(string(out), `<script type="module">`)
	bodyCloseIdx := strings.Index(strings.ToLower(string(out)), `</body>`)
	if scriptIdx == -1 || bodyCloseIdx == -1 || scriptIdx > bodyCloseIdx {
		t.Fatalf("expected script to be injected before </body>")
	}
}

func TestInjectQIPFormRuntimeMissingModule(t *testing.T) {
	htmlBody := []byte(`<html><body><qip-form name="missing"></qip-form></body></html>`)
	_, _, err := injectQIPFormRuntime(htmlBody, map[string][]byte{}, map[string][32]byte{})
	if err == nil {
		t.Fatal("expected error for missing form module")
	}
}
