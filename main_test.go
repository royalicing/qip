package main

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
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
