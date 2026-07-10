package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"image"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
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
	root := t.TempDir()
	mustWrite := func(rel string) {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(full, []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	mustWrite("index.html")
	mustWrite("docs/index.html")
	mustWrite("guide/start.md")
	mustWrite("how-it-works.uri")
	mustWrite("images/logo.png")

	routes, err := qinternal.BuildContentRoutes(root, qinternal.DefaultRouteOptions())
	if err != nil {
		t.Fatalf("BuildContentRoutes: %v", err)
	}

	checks := map[string]string{
		"/index.html":       "index.html",
		"/":                 "index.html",
		"/docs/index.html":  "docs/index.html",
		"/docs":             "docs/index.html",
		"/docs/":            "docs/index.html",
		"/guide/start.md":   "guide/start.md",
		"/guide/start":      "guide/start.md",
		"/how-it-works.uri": "how-it-works.uri",
		"/how-it-works":     "how-it-works.uri",
		"/images/logo.png":  "images/logo.png",
	}
	for requestPath, wantRel := range checks {
		route, ok := routes[requestPath]
		if !ok {
			t.Fatalf("missing route for %s", requestPath)
		}
		wantFull := filepath.Join(root, filepath.FromSlash(wantRel))
		if route.FilePath != wantFull {
			t.Fatalf("route %s file=%s, want %s", requestPath, route.FilePath, wantFull)
		}
	}
	if route, ok := routes["/how-it-works"]; !ok {
		t.Fatalf("missing route for /how-it-works")
	} else if route.SourceMIME != "text/uri-list" {
		t.Fatalf("route /how-it-works source mime=%q, want %q", route.SourceMIME, "text/uri-list")
	}
}

func TestContentRequestPathsWithSymlinks(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()

	mustWrite := func(base string, rel string, data []byte) {
		full := filepath.Join(base, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(full, data, 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	mustWrite(external, "docs/index.html", []byte("<h1>Docs</h1>"))
	mustWrite(external, "docs/guide.md", []byte("Guide"))
	mustWrite(external, "shared.txt", []byte("Shared"))

	if err := os.Symlink(filepath.Join(external, "docs"), filepath.Join(root, "docs")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if err := os.Symlink(filepath.Join(external, "shared.txt"), filepath.Join(root, "shared.txt")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	routes, err := qinternal.BuildContentRoutes(root, qinternal.DefaultRouteOptions())
	if err != nil {
		t.Fatalf("BuildContentRoutes: %v", err)
	}

	checks := map[string]string{
		"/docs/index.html": "docs/index.html",
		"/docs":            "docs/index.html",
		"/docs/":           "docs/index.html",
		"/docs/guide.md":   "docs/guide.md",
		"/docs/guide":      "docs/guide.md",
		"/shared.txt":      "shared.txt",
	}
	for requestPath, wantRel := range checks {
		route, ok := routes[requestPath]
		if !ok {
			t.Fatalf("missing route for %s", requestPath)
		}
		wantFull := filepath.Join(root, filepath.FromSlash(wantRel))
		if route.FilePath != wantFull {
			t.Fatalf("route %s file=%s, want %s", requestPath, route.FilePath, wantFull)
		}
	}
}

func TestResolveDevContentRoute(t *testing.T) {
	routes := map[string]qinternal.ContentRoute{
		"/docs":  {FilePath: "docs/index.md", SourceMIME: "text/markdown"},
		"/docs/": {FilePath: "docs/index.md", SourceMIME: "text/markdown"},
	}

	if _, ok := qinternal.ResolveContentRoute(routes, "/docs", qinternal.DefaultRouteOptions()); !ok {
		t.Fatal("expected /docs to resolve")
	}
	if _, ok := qinternal.ResolveContentRoute(routes, "/docs/", qinternal.DefaultRouteOptions()); !ok {
		t.Fatal("expected /docs/ to resolve")
	}
	if _, ok := qinternal.ResolveContentRoute(routes, "/missing", qinternal.DefaultRouteOptions()); ok {
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

	t.Run("trailing flags after content are normalized", func(t *testing.T) {
		in := []string{"docs/", "--recipes", "recipes/", "--mode", "dev", "-p", "4004"}
		got := normalizeDevArgs(in)
		want := []string{"--recipes", "recipes/", "--mode", "dev", "-p", "4004", "docs/"}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("args=%v, want %v", got, want)
		}
	})
}

func TestNormalizeRunArgs(t *testing.T) {
	in := []string{
		"modules/utf8/trim.wasm",
		"?x=1",
		"modules/utf8/wc.wasm",
		"-o",
		"out.txt",
		"--timeout-ms",
		"2500",
		"--max-memory",
		"1048576",
		"--fixed-memory",
	}
	got := normalizeRunArgs(in)
	want := []string{
		"-o",
		"out.txt",
		"--timeout-ms",
		"2500",
		"--max-memory",
		"1048576",
		"--fixed-memory",
		"modules/utf8/trim.wasm",
		"?x=1",
		"modules/utf8/wc.wasm",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}

	inWithDashDash := []string{"module.wasm", "--", "--not-a-flag"}
	gotWithDashDash := normalizeRunArgs(inWithDashDash)
	wantWithDashDash := []string{"--", "module.wasm", "--not-a-flag"}
	if !reflect.DeepEqual(gotWithDashDash, wantWithDashDash) {
		t.Fatalf("args=%v, want %v", gotWithDashDash, wantWithDashDash)
	}
}

func TestNormalizeRouteArgs(t *testing.T) {
	in := []string{"docs/", "--recipes", "recipes/", "--mode", "dev"}
	got := normalizeRouteArgs(in)
	want := []string{"--recipes", "recipes/", "--mode", "dev", "docs/"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}

func TestScaleRouteWARCTransformTimeout(t *testing.T) {
	base := 5 * time.Second
	if got := scaleRouteWARCTransformTimeout(base, 0); got != base {
		t.Fatalf("route count 0 timeout=%v, want %v", got, base)
	}
	if got := scaleRouteWARCTransformTimeout(base, 1); got != base {
		t.Fatalf("route count 1 timeout=%v, want %v", got, base)
	}
	if got := scaleRouteWARCTransformTimeout(base, 5); got != 25*time.Second {
		t.Fatalf("route count 5 timeout=%v, want 25s", got)
	}
}

func TestParseModuleSpecs(t *testing.T) {
	t.Run("associates uniform queries with prior module", func(t *testing.T) {
		specs, err := parseModuleSpecs([]string{
			"a.wasm",
			"?alpha=1&beta=2",
			"b.wasm",
			"?gamma=3",
			"?gamma=4",
		}, "run")
		if err != nil {
			t.Fatalf("parseModuleSpecs error: %v", err)
		}
		if len(specs) != 2 {
			t.Fatalf("len(specs)=%d, want 2", len(specs))
		}
		if specs[0].path != "a.wasm" {
			t.Fatalf("specs[0].path=%q, want %q", specs[0].path, "a.wasm")
		}
		if specs[0].uniforms["alpha"] != "1" || specs[0].uniforms["beta"] != "2" {
			t.Fatalf("unexpected uniforms for first module: %+v", specs[0].uniforms)
		}
		if specs[1].path != "b.wasm" {
			t.Fatalf("specs[1].path=%q, want %q", specs[1].path, "b.wasm")
		}
		if specs[1].uniforms["gamma"] != "4" {
			t.Fatalf("specs[1].uniforms[gamma]=%q, want %q", specs[1].uniforms["gamma"], "4")
		}
	})

	t.Run("rejects uniform query before component path", func(t *testing.T) {
		_, err := parseModuleSpecs([]string{"?x=1"}, "run")
		if err == nil {
			t.Fatal("expected parse error")
		}
		if !strings.Contains(err.Error(), "run uniform query") {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}

func TestParseUniformInt(t *testing.T) {
	t.Run("parses decimal values", func(t *testing.T) {
		got, err := parseUniformInt("123", 64)
		if err != nil {
			t.Fatalf("parseUniformInt error: %v", err)
		}
		if got != 123 {
			t.Fatalf("got %d, want 123", got)
		}
	})

	t.Run("parses hex with 0x prefix", func(t *testing.T) {
		got, err := parseUniformInt("0xff4511ff", 64)
		if err != nil {
			t.Fatalf("parseUniformInt error: %v", err)
		}
		if got != 4282716671 {
			t.Fatalf("got %d, want 4282716671", got)
		}
	})

	t.Run("parses signed hex with 0x prefix", func(t *testing.T) {
		got, err := parseUniformInt("-0x7f", 64)
		if err != nil {
			t.Fatalf("parseUniformInt error: %v", err)
		}
		if got != -127 {
			t.Fatalf("got %d, want -127", got)
		}
	})

	t.Run("rejects missing hex prefix", func(t *testing.T) {
		if _, err := parseUniformInt("ff4511ff", 64); err == nil {
			t.Fatal("expected parse error")
		}
	})

	t.Run("rejects invalid hex after prefix", func(t *testing.T) {
		if _, err := parseUniformInt("0xgg", 64); err == nil {
			t.Fatal("expected parse error")
		}
	})

	t.Run("rejects i32 overflow", func(t *testing.T) {
		if _, err := parseUniformInt("0xffffffff", 32); err == nil {
			t.Fatal("expected parse error")
		}
	})
}

func TestParseUniformHexUint(t *testing.T) {
	t.Run("parses u32 hex with 0x prefix", func(t *testing.T) {
		got, isHex, err := parseUniformHexUint("0xff4511ff", 32)
		if err != nil {
			t.Fatalf("parseUniformHexUint error: %v", err)
		}
		if !isHex {
			t.Fatal("expected hex prefix detection")
		}
		if got != 4282716671 {
			t.Fatalf("got %d, want 4282716671", got)
		}
	})

	t.Run("parses u64 max hex with 0x prefix", func(t *testing.T) {
		got, isHex, err := parseUniformHexUint("0xffffffffffffffff", 64)
		if err != nil {
			t.Fatalf("parseUniformHexUint error: %v", err)
		}
		if !isHex {
			t.Fatal("expected hex prefix detection")
		}
		if got != ^uint64(0) {
			t.Fatalf("got %d, want %d", got, ^uint64(0))
		}
	})

	t.Run("ignores non-hex input", func(t *testing.T) {
		_, isHex, err := parseUniformHexUint("123", 32)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if isHex {
			t.Fatal("expected non-hex input to be ignored")
		}
	})

	t.Run("rejects invalid hex", func(t *testing.T) {
		if _, isHex, err := parseUniformHexUint("0xgg", 32); err == nil || !isHex {
			t.Fatal("expected parse error with detected hex prefix")
		}
	})

	t.Run("rejects u32 overflow", func(t *testing.T) {
		if _, isHex, err := parseUniformHexUint("0x100000000", 32); err == nil || !isHex {
			t.Fatal("expected overflow parse error with detected hex prefix")
		}
	})
}

func TestBuildRouteListEntries(t *testing.T) {
	state := &devRuntimeState{
		contentRoutes: map[string]qinternal.ContentRoute{
			"/about":        {FilePath: "docs/about.md", SourceMIME: "text/markdown"},
			"/about/":       {FilePath: "docs/about.md", SourceMIME: "text/markdown"},
			"/images/logo":  {FilePath: "docs/images/logo.png", SourceMIME: "image/png"},
			"/images/logo/": {FilePath: "docs/images/logo.png", SourceMIME: "image/png"},
		},
		routeOptions: qinternal.DefaultRouteOptions(),
		recipeChains: map[string]*qinternal.Pipeline{
			"text/markdown": &qinternal.Pipeline{},
		},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/about", ContentType: "text/html"},
		{Method: "HEAD", Path: "/about", ContentType: "text/html"},
		{Method: "GET", Path: "/images/logo", ContentType: "image/png"},
		{Method: "HEAD", Path: "/images/logo", ContentType: "image/png"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestBuildRouteListEntriesIncludesURIListRedirect(t *testing.T) {
	state := &devRuntimeState{
		contentRoutes: map[string]qinternal.ContentRoute{
			"/how-it-works":     {FilePath: "site/how-it-works.uri", SourceMIME: "text/uri-list"},
			"/how-it-works.uri": {FilePath: "site/how-it-works.uri", SourceMIME: "text/uri-list"},
		},
		routeOptions: qinternal.DefaultRouteOptions(),
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/how-it-works", ContentType: "text/uri-list"},
		{Method: "HEAD", Path: "/how-it-works", ContentType: "text/uri-list"},
		{Method: "GET", Path: "/how-it-works.uri", ContentType: "text/uri-list"},
		{Method: "HEAD", Path: "/how-it-works.uri", ContentType: "text/uri-list"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestFirstURIListTarget(t *testing.T) {
	t.Run("first non-comment line", func(t *testing.T) {
		body := []byte("# old route\n\n/docs/how-it-works\nhttps://example.com/ignored\n")
		got, ok := firstURIListTarget(body)
		if !ok {
			t.Fatal("expected redirect target")
		}
		if got != "/docs/how-it-works" {
			t.Fatalf("target=%q, want %q", got, "/docs/how-it-works")
		}
	})

	t.Run("supports crlf and bom", func(t *testing.T) {
		body := []byte("\xEF\xBB\xBF#comment\r\n  /docs/how-it-works  \r\n")
		got, ok := firstURIListTarget(body)
		if !ok {
			t.Fatal("expected redirect target")
		}
		if got != "/docs/how-it-works" {
			t.Fatalf("target=%q, want %q", got, "/docs/how-it-works")
		}
	})

	t.Run("missing target", func(t *testing.T) {
		if _, ok := firstURIListTarget([]byte("#comment\n \n")); ok {
			t.Fatal("expected no redirect target")
		}
	})
}

func TestDevHandlerServesURIListRedirect(t *testing.T) {
	contentRoot := t.TempDir()
	redirectPath := filepath.Join(contentRoot, "how-it-works.uri")
	if err := os.WriteFile(redirectPath, []byte("# move\n/docs/how-it-works\n"), 0o644); err != nil {
		t.Fatalf("write redirect file: %v", err)
	}

	state := &devRuntimeState{
		contentRoutes: map[string]qinternal.ContentRoute{
			"/how-it-works":     {FilePath: redirectPath, SourceMIME: "text/uri-list"},
			"/how-it-works.uri": {FilePath: redirectPath, SourceMIME: "text/uri-list"},
		},
		routeOptions:  qinternal.DefaultRouteOptions(),
		recipeChains:  map[string]*qinternal.Pipeline{},
		recipeDigests: map[string][][32]byte{},
	}
	var stateMu sync.RWMutex
	handler := newDevRequestHandler("test", &stateMu, &state, nil, nil, qinternal.DefaultRouteOptions(), routeHandlerTimeouts{})

	resp, err := qinternal.ServeInProcessHTTP(handler, http.MethodGet, "/how-it-works", nil)
	if err != nil {
		t.Fatalf("ServeInProcessHTTP: %v", err)
	}
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("status=%d, want %d", resp.StatusCode, http.StatusFound)
	}
	if got := resp.Header.Get("Location"); got != "/docs/how-it-works" {
		t.Fatalf("Location=%q, want %q", got, "/docs/how-it-works")
	}
	if got := resp.Header.Get("ETag"); got != "" {
		t.Fatalf("ETag=%q, want empty", got)
	}
}

func TestBuildRouteListEntriesMarkdownExtensionServesRaw(t *testing.T) {
	state := &devRuntimeState{
		contentRoutes: map[string]qinternal.ContentRoute{
			"/guide":    {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
			"/guide.md": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
		},
		routeOptions: qinternal.DefaultRouteOptions(),
		recipeChains: map[string]*qinternal.Pipeline{
			"text/markdown": &qinternal.Pipeline{},
		},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/guide", ContentType: "text/html"},
		{Method: "HEAD", Path: "/guide", ContentType: "text/html"},
		{Method: "GET", Path: "/guide.md", ContentType: "text/markdown"},
		{Method: "HEAD", Path: "/guide.md", ContentType: "text/markdown"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestBuildRouteListEntriesUsesRecipeOutputContentType(t *testing.T) {
	state := &devRuntimeState{
		contentRoutes: map[string]qinternal.ContentRoute{
			"/guide":    {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
			"/guide.md": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
		},
		routeOptions: qinternal.DefaultRouteOptions(),
		recipeChains: map[string]*qinternal.Pipeline{
			"text/markdown": &qinternal.Pipeline{},
		},
		recipeOutput: map[string]string{
			"text/markdown": "application/xhtml+xml",
		},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/guide", ContentType: "application/xhtml+xml"},
		{Method: "HEAD", Path: "/guide", ContentType: "application/xhtml+xml"},
		{Method: "GET", Path: "/guide.md", ContentType: "text/markdown"},
		{Method: "HEAD", Path: "/guide.md", ContentType: "text/markdown"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestBuildRouteListEntriesIncludesComponentAssets(t *testing.T) {
	state := &devRuntimeState{
		contentRoutes: map[string]qinternal.ContentRoute{
			"/guide": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
		},
		routeOptions: qinternal.DefaultRouteOptions(),
		componentAssets: map[string]componentAsset{
			"/components/bytes/base64-encode.wasm": {contentType: "application/wasm"},
		},
		componentRequestPaths: []string{"/components/bytes/base64-encode.wasm"},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/components/bytes/base64-encode.wasm", ContentType: "application/wasm"},
		{Method: "HEAD", Path: "/components/bytes/base64-encode.wasm", ContentType: "application/wasm"},
		{Method: "GET", Path: "/guide", ContentType: "text/markdown"},
		{Method: "HEAD", Path: "/guide", ContentType: "text/markdown"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestResolveRecipeSourceResponse(t *testing.T) {
	state := &devRuntimeState{
		recipeSourceAssets: []qinternal.RecipeSourceAsset{
			{
				RequestPath: "/view-source/recipes/text/markdown/10-markdown-basic.zig",
				Body:        []byte("const x = 1;"),
				ContentType: "text/plain; charset=utf-8",
			},
		},
		recipeSourceByPath: map[string]qinternal.RecipeSourceAsset{
			"/view-source/recipes/text/markdown/10-markdown-basic.zig": {
				RequestPath: "/view-source/recipes/text/markdown/10-markdown-basic.zig",
				Body:        []byte("const x = 1;"),
				ContentType: "text/plain; charset=utf-8",
			},
			"/view-source/components/utf8/trim.zig": {
				RequestPath: "/view-source/components/utf8/trim.zig",
				Body:        []byte("const std = @import(\"std\");"),
				ContentType: "text/plain; charset=utf-8",
			},
		},
		recipeSourceIndex: []byte("<!doctype html><h1>/view-source</h1><h2>Recipes</h2><h2>Content</h2>"),
	}

	indexResp, ok := resolveRecipeSourceResponse("/view-source", state)
	if !ok {
		t.Fatal("expected index response")
	}
	if indexResp.StatusCode != http.StatusOK {
		t.Fatalf("index status=%d, want %d", indexResp.StatusCode, http.StatusOK)
	}
	if got := indexResp.Header.Get("Content-Type"); got != "text/html; charset=utf-8" {
		t.Fatalf("index content-type=%q, want %q", got, "text/html; charset=utf-8")
	}
	if _, ok := resolveRecipeSourceResponse("/view-source/recipes", state); ok {
		t.Fatalf("did not expect /view-source/recipes to resolve as an index page")
	}

	assetResp, ok := resolveRecipeSourceResponse("/view-source/recipes/text/markdown/10-markdown-basic.zig", state)
	if !ok {
		t.Fatal("expected asset response")
	}
	if got := assetResp.Header.Get("Content-Type"); got != "text/plain; charset=utf-8" {
		t.Fatalf("asset content-type=%q, want %q", got, "text/plain; charset=utf-8")
	}
	if string(assetResp.Body) != "const x = 1;" {
		t.Fatalf("asset body=%q", string(assetResp.Body))
	}

	if _, ok := resolveRecipeSourceResponse("/view-source/recipes/missing.zig", state); ok {
		t.Fatal("expected missing asset to not resolve")
	}

	componentAssetResp, ok := resolveRecipeSourceResponse("/view-source/components/utf8/trim.zig", state)
	if !ok {
		t.Fatal("expected component source asset response")
	}
	if got := componentAssetResp.Header.Get("Content-Type"); got != "text/plain; charset=utf-8" {
		t.Fatalf("component asset content-type=%q, want %q", got, "text/plain; charset=utf-8")
	}
	if string(componentAssetResp.Body) != "const std = @import(\"std\");" {
		t.Fatalf("component asset body=%q", string(componentAssetResp.Body))
	}
}

func TestRunDelayedStdinDoesNotFailExportResolution(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=TestHelperRunModuleCLI", "--", "examples/html-aria-extractor.wasm")
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("start helper: %v", err)
	}

	// Delay long enough to fail old behavior where wasm timeout started before stdin read.
	time.Sleep(500 * time.Millisecond)
	if _, err := stdin.Write([]byte(`<a href="/x">X</a>`)); err != nil {
		_ = cmd.Process.Kill()
		t.Fatalf("write stdin: %v", err)
	}
	_ = stdin.Close()

	if err := cmd.Wait(); err != nil {
		t.Fatalf("helper failed: %v\nstderr: %s\nstdout: %s", err, stderr.String(), stdout.String())
	}
	if !strings.Contains(stdout.String(), "link: X") {
		t.Fatalf("unexpected output: %q", stdout.String())
	}
}

func TestRunModuleExecutionErrorIncludesModulePath(t *testing.T) {
	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"--timeout-ms",
		"1",
		"examples/infinite-loop.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		t.Fatalf("expected run to fail, stdout=%q stderr=%q", stdout.String(), stderr.String())
	}

	gotErr := stderr.String()
	if !strings.Contains(gotErr, "examples/infinite-loop.wasm:") {
		t.Fatalf("stderr=%q, want component path prefix", gotErr)
	}
	if !strings.Contains(gotErr, "Wasm module exceeded the execution time limit") {
		t.Fatalf("stderr=%q, want execution timeout message", gotErr)
	}
}

func TestRunAppliesUniformQueries(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("line1\nline2\nline3"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}

	runOnce := func(extraArgs ...string) []byte {
		args := []string{"-test.run=TestHelperRunModuleCLI", "--", "-i", inputPath, "examples/text-to-bmp.wasm"}
		args = append(args, extraArgs...)
		cmd := exec.Command(os.Args[0], args...)
		cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
		var stdout bytes.Buffer
		var stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
		}
		return stdout.Bytes()
	}

	base := runOnce()
	withUniform := runOnce("?leading=40")

	baseW, baseH, err := qinternal.GetBMPDimensions(base)
	if err != nil {
		t.Fatalf("base output is not bmp: %v", err)
	}
	withUniformW, withUniformH, err := qinternal.GetBMPDimensions(withUniform)
	if err != nil {
		t.Fatalf("uniform output is not bmp: %v", err)
	}

	if baseW != withUniformW {
		t.Fatalf("width changed unexpectedly: base=%d uniform=%d", baseW, withUniformW)
	}
	if baseH == withUniformH {
		t.Fatalf("expected height to change with uniform; base=%d uniform=%d", baseH, withUniformH)
	}
}

func TestRunAppliesColsUniform(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("abcdefghij"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}

	runOnce := func(extraArgs ...string) []byte {
		args := []string{"-test.run=TestHelperRunModuleCLI", "--", "-i", inputPath, "examples/text-to-bmp.wasm"}
		args = append(args, extraArgs...)
		cmd := exec.Command(os.Args[0], args...)
		cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
		var stdout bytes.Buffer
		var stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
		}
		return stdout.Bytes()
	}

	base := runOnce()
	withUniform := runOnce("?cols=10")

	baseW, baseH, err := qinternal.GetBMPDimensions(base)
	if err != nil {
		t.Fatalf("base output is not bmp: %v", err)
	}
	withUniformW, withUniformH, err := qinternal.GetBMPDimensions(withUniform)
	if err != nil {
		t.Fatalf("uniform output is not bmp: %v", err)
	}

	if baseW == withUniformW {
		t.Fatalf("expected width to change with uniform; base=%d uniform=%d", baseW, withUniformW)
	}
	if withUniformW != 80 {
		t.Fatalf("uniform width=%d, want %d", withUniformW, 80)
	}
	if withUniformH < baseH {
		t.Fatalf("height unexpectedly decreased: base=%d uniform=%d", baseH, withUniformH)
	}
}

func TestRunOutputFlagWritesToFile(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("  hello  \n"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}
	outputPath := filepath.Join(t.TempDir(), "out.txt")

	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"-i",
		inputPath,
		"-o",
		outputPath,
		"modules/utf8/trim.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout should be empty when -o is set, got %q", stdout.String())
	}

	got, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read output file: %v", err)
	}
	if string(got) != "hello" {
		t.Fatalf("output file=%q, want %q", string(got), "hello")
	}
}

func TestRunOutputFlagAtEndWritesToFile(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("  hello  \n"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}
	outputPath := filepath.Join(t.TempDir(), "out.txt")

	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"-i",
		inputPath,
		"modules/utf8/trim.wasm",
		"-o",
		outputPath,
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout should be empty when -o is set, got %q", stdout.String())
	}

	got, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read output file: %v", err)
	}
	if string(got) != "hello" {
		t.Fatalf("output file=%q, want %q", string(got), "hello")
	}
}

func TestRunDoubleDashTreatsFollowingAsPositional(t *testing.T) {
	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"--",
		"--not-a-flag",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		t.Fatalf("expected run to fail due to missing module file")
	}
	gotErr := stderr.String()
	if strings.Contains(gotErr, "flag provided but not defined") {
		t.Fatalf("stderr=%q, expected '--not-a-flag' to be treated as positional", gotErr)
	}
	if !strings.Contains(gotErr, "open --not-a-flag") {
		t.Fatalf("stderr=%q, expected file-open error for positional component path", gotErr)
	}
}

func TestRunOutputFlagImageReencodeByExtension(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("qip"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}

	tests := []struct {
		name     string
		fileName string
		checkSig []byte
	}{
		{name: "png", fileName: "out.png", checkSig: []byte{0x89, 'P', 'N', 'G'}},
		{name: "jpg", fileName: "out.jpg", checkSig: []byte{0xFF, 0xD8}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			outputPath := filepath.Join(t.TempDir(), tc.fileName)
			cmd := exec.Command(
				os.Args[0],
				"-test.run=TestHelperRunModuleCLI",
				"--",
				"-i",
				inputPath,
				"-o",
				outputPath,
				"modules/utf8/text-to-bmp.wasm",
			)
			cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr

			if err := cmd.Run(); err != nil {
				t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
			}
			if stdout.Len() != 0 {
				t.Fatalf("stdout should be empty when -o is set, got %q", stdout.String())
			}

			got, err := os.ReadFile(outputPath)
			if err != nil {
				t.Fatalf("read output file: %v", err)
			}
			if len(got) < len(tc.checkSig) || !bytes.Equal(got[:len(tc.checkSig)], tc.checkSig) {
				t.Fatalf("unexpected file signature for %s", tc.fileName)
			}
			img, _, err := image.Decode(bytes.NewReader(got))
			if err != nil {
				t.Fatalf("decode encoded image: %v", err)
			}
			if img.Bounds().Dx() <= 0 || img.Bounds().Dy() <= 0 {
				t.Fatalf("invalid output image bounds: %v", img.Bounds())
			}
		})
	}
}

func TestRunInteractiveModuleOutputsFirstFrameBMP(t *testing.T) {
	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"modules/interactive/tile-world-12x12.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}
	if stdout.Len() == 0 {
		t.Fatal("expected BMP bytes on stdout")
	}

	w, h, err := qinternal.GetBMPDimensions(stdout.Bytes())
	if err != nil {
		t.Fatalf("stdout was not BMP: %v", err)
	}
	if w != 288 || h != 288 {
		t.Fatalf("bmp dimensions=%dx%d, want 288x288", w, h)
	}
}

func TestRunOutputFlagImageReencodeRejectsNonImageOutput(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "in.txt")
	if err := os.WriteFile(inputPath, []byte("hello"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}
	outputPath := filepath.Join(t.TempDir(), "out.png")

	cmd := exec.Command(
		os.Args[0],
		"-test.run=TestHelperRunModuleCLI",
		"--",
		"-i",
		inputPath,
		"-o",
		outputPath,
		"modules/utf8/trim.wasm",
	)
	cmd.Env = append(os.Environ(), "QIP_HELPER_RUN_MODULE_CLI=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		t.Fatalf("expected run to fail for non-image output to .png")
	}
	if !strings.Contains(stderr.String(), "cannot encode non-image output as image") {
		t.Fatalf("stderr=%q, want image conversion error", stderr.String())
	}
	if _, statErr := os.Stat(outputPath); !os.IsNotExist(statErr) {
		t.Fatalf("output file should not be created on error, statErr=%v", statErr)
	}
}

func compileWasmModuleForTest(t *testing.T, ctx context.Context, runtime wazero.Runtime, path string) wazero.CompiledModule {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read module %s: %v", path, err)
	}
	compiled, err := runtime.CompileModule(ctx, body)
	if err != nil {
		t.Fatalf("compile module %s: %v", path, err)
	}
	return compiled
}

func TestExecuteModuleReadsOutputPtrAfterRender(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	// The module starts with output_ptr pointing at "stale". render then chooses
	// either input_ptr for already-trimmed input or a scratch buffer otherwise.
	wasmBytes := []byte{
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0a, 0x02, 0x60,
		0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x03, 0x06, 0x05, 0x00,
		0x00, 0x00, 0x00, 0x01, 0x05, 0x04, 0x01, 0x01, 0x01, 0x01, 0x06, 0x19,
		0x04, 0x7f, 0x00, 0x41, 0x80, 0x08, 0x0b, 0x7f, 0x00, 0x41, 0xc0, 0x00,
		0x0b, 0x7f, 0x00, 0x41, 0xc0, 0x00, 0x0b, 0x7f, 0x01, 0x41, 0x80, 0x18,
		0x0b, 0x07, 0x4f, 0x06, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02,
		0x00, 0x09, 0x69, 0x6e, 0x70, 0x75, 0x74, 0x5f, 0x70, 0x74, 0x72, 0x00,
		0x00, 0x0e, 0x69, 0x6e, 0x70, 0x75, 0x74, 0x5f, 0x75, 0x74, 0x66, 0x38,
		0x5f, 0x63, 0x61, 0x70, 0x00, 0x01, 0x0a, 0x6f, 0x75, 0x74, 0x70, 0x75,
		0x74, 0x5f, 0x70, 0x74, 0x72, 0x00, 0x02, 0x0f, 0x6f, 0x75, 0x74, 0x70,
		0x75, 0x74, 0x5f, 0x75, 0x74, 0x66, 0x38, 0x5f, 0x63, 0x61, 0x70, 0x00,
		0x03, 0x06, 0x72, 0x65, 0x6e, 0x64, 0x65, 0x72, 0x00, 0x04, 0x0a, 0x83,
		0x01, 0x05, 0x04, 0x00, 0x23, 0x00, 0x0b, 0x04, 0x00, 0x23, 0x01, 0x0b,
		0x04, 0x00, 0x23, 0x03, 0x0b, 0x04, 0x00, 0x23, 0x02, 0x0b, 0x6d, 0x00,
		0x20, 0x00, 0x41, 0x04, 0x46, 0x23, 0x00, 0x2d, 0x00, 0x00, 0x41, 0xf4,
		0x00, 0x46, 0x23, 0x00, 0x41, 0x01, 0x6a, 0x2d, 0x00, 0x00, 0x41, 0xf2,
		0x00, 0x46, 0x23, 0x00, 0x41, 0x02, 0x6a, 0x2d, 0x00, 0x00, 0x41, 0xe9,
		0x00, 0x46, 0x23, 0x00, 0x41, 0x03, 0x6a, 0x2d, 0x00, 0x00, 0x41, 0xed,
		0x00, 0x46, 0x71, 0x71, 0x71, 0x71, 0x04, 0x40, 0x23, 0x00, 0x24, 0x03,
		0x20, 0x00, 0x0f, 0x0b, 0x41, 0x80, 0x10, 0x24, 0x03, 0x41, 0x80, 0x10,
		0x41, 0xf4, 0x00, 0x3a, 0x00, 0x00, 0x41, 0x81, 0x10, 0x41, 0xf2, 0x00,
		0x3a, 0x00, 0x00, 0x41, 0x82, 0x10, 0x41, 0xe9, 0x00, 0x3a, 0x00, 0x00,
		0x41, 0x83, 0x10, 0x41, 0xed, 0x00, 0x3a, 0x00, 0x00, 0x41, 0x04, 0x0b,
		0x0b, 0x0c, 0x01, 0x00, 0x41, 0x80, 0x18, 0x0b, 0x05, 0x73, 0x74, 0x61,
		0x6c, 0x65,
	}

	compiled, err := runtime.CompileModule(ctx, wasmBytes)
	if err != nil {
		t.Fatalf("compile module: %v", err)
	}
	defer compiled.Close(ctx)

	for _, tc := range []struct {
		name  string
		input []byte
	}{
		{name: "already-trimmed input is returned from input_ptr", input: []byte("trim")},
		{name: "padded input is returned from scratch output buffer", input: []byte(" trim ")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			exec, err := executeModuleWithInput(
				ctx,
				runtime,
				compiled,
				tc.input,
				options{},
				"test-deferred-output-ptr",
				nil,
				"",
				false,
			)
			if err != nil {
				t.Fatalf("execute module: %v", err)
			}
			if got := string(exec.output.bytes); got != "trim" {
				t.Fatalf("output=%q, want %q", got, "trim")
			}
		})
	}
}

func TestContentTypeCheckingModesForRunModule(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	compiled := compileWasmModuleForTest(t, ctx, runtime, "examples/html-aria-extractor.wasm")
	defer compiled.Close(ctx)

	input := []byte(`<a href="/x">X</a>`)
	moduleName := "test-html-aria"

	_, err := executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		input,
		options{contentTypeChecking: ContentTypeCheckingStrong},
		moduleName,
		nil,
		"text/plain",
		false,
	)
	if err == nil {
		t.Fatal("expected strong content type mismatch error")
	}
	if !strings.Contains(err.Error(), "content type check failed") {
		t.Fatalf("unexpected error: %v", err)
	}

	_, err = executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		input,
		options{contentTypeChecking: ContentTypeCheckingNone},
		moduleName,
		nil,
		"text/plain",
		false,
	)
	if err != nil {
		t.Fatalf("none mode should skip content type mismatch: %v", err)
	}
}

func TestTrustFirstStageContentTypePropagation(t *testing.T) {
	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)

	compiled := compileWasmModuleForTest(t, ctx, runtime, "examples/html-link-extractor.wasm")
	defer compiled.Close(ctx)

	exec, err := executeModuleWithInput(
		ctx,
		runtime,
		compiled,
		[]byte(`<a href="/x">X</a>`),
		options{contentTypeChecking: ContentTypeCheckingStrong},
		"test-html-link",
		nil,
		"",
		true,
	)
	if err != nil {
		t.Fatalf("expected trusted first-stage input to pass: %v", err)
	}
	if exec.outputContentType != "text/html" {
		t.Fatalf("outputContentType=%q, want %q", exec.outputContentType, "text/html")
	}
}

func TestHelperRunModuleCLI(t *testing.T) {
	if os.Getenv("QIP_HELPER_RUN_MODULE_CLI") != "1" {
		t.Skip("helper process")
	}
	args := os.Args
	sep := -1
	for i := range args {
		if args[i] == "--" {
			sep = i
			break
		}
	}
	if sep == -1 || sep+1 >= len(args) {
		os.Exit(2)
	}
	run(args[sep+1:])
	os.Exit(0)
}

func TestParseRuntimeMode(t *testing.T) {
	t.Run("dev", func(t *testing.T) {
		got, err := parseRuntimeMode("dev")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != modeDev {
			t.Fatalf("mode=%q, want %q", got, modeDev)
		}
	})

	t.Run("prod uppercase", func(t *testing.T) {
		got, err := parseRuntimeMode("PROD")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != modeProd {
			t.Fatalf("mode=%q, want %q", got, modeProd)
		}
	})

	t.Run("invalid", func(t *testing.T) {
		if _, err := parseRuntimeMode("staging"); err == nil {
			t.Fatal("expected invalid mode error")
		}
	})
}

func TestScanRecipeModuleStampsDetectsChanges(t *testing.T) {
	root := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmA := filepath.Join(recipeDir, "10-a.wasm")
	if err := os.WriteFile(wasmA, []byte{0x00, 0x61, 0x73, 0x6d}, 0o644); err != nil {
		t.Fatalf("write wasm a: %v", err)
	}

	first, err := scanRecipeModuleStamps(root)
	if err != nil {
		t.Fatalf("scanRecipeModuleStamps error: %v", err)
	}

	time.Sleep(2 * time.Millisecond)
	if err := os.WriteFile(wasmA, []byte{0x00, 0x61, 0x73, 0x6d, 0x01}, 0o644); err != nil {
		t.Fatalf("rewrite wasm a: %v", err)
	}

	second, err := scanRecipeModuleStamps(root)
	if err != nil {
		t.Fatalf("scanRecipeModuleStamps error: %v", err)
	}
	if recipeModuleStampsEqual(first, second) {
		t.Fatal("expected stamp maps to differ after mtime/size change")
	}

	wasmB := filepath.Join(recipeDir, "20-b.wasm")
	if err := os.WriteFile(wasmB, []byte{0x00, 0x61, 0x73, 0x6d}, 0o644); err != nil {
		t.Fatalf("write wasm b: %v", err)
	}

	third, err := scanRecipeModuleStamps(root)
	if err != nil {
		t.Fatalf("scanRecipeModuleStamps error: %v", err)
	}
	if recipeModuleStampsEqual(second, third) {
		t.Fatal("expected stamp maps to differ after adding new module")
	}
}

func TestScanRecipeModuleStampsSupportsSymlinkedRecipeComponents(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()
	recipeDir := filepath.Join(root, "text", "markdown")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	wasmPath := filepath.Join(external, "10-linked.wasm")
	if err := os.WriteFile(wasmPath, []byte{0x00, 0x61, 0x73, 0x6d}, 0o644); err != nil {
		t.Fatalf("write wasm: %v", err)
	}
	if err := os.Symlink(wasmPath, filepath.Join(recipeDir, "10-linked.wasm")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	stamps, err := scanRecipeModuleStamps(root)
	if err != nil {
		t.Fatalf("scanRecipeModuleStamps error: %v", err)
	}
	if _, ok := stamps["text/markdown/10-linked.wasm"]; !ok {
		t.Fatalf("expected stamp for symlinked recipe module")
	}
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
		closePipelines(context.Background(), chains)
	})

	chain, ok := chains["text/markdown"]
	if !ok || chain == nil {
		t.Fatalf("expected text/markdown chain")
	}
	if got := len(digests["text/markdown"]); got != 1 {
		t.Fatalf("digest count=%d, want 1", got)
	}
}

func TestLoadRecipeChainsSupportsSymlinkedRecipeComponents(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()

	if err := os.MkdirAll(filepath.Join(external, "text", "markdown"), 0o755); err != nil {
		t.Fatalf("mkdir external: %v", err)
	}
	wasmBytes, err := os.ReadFile(filepath.Join("examples", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(external, "text", "markdown", "10-linked.wasm"), wasmBytes, 0o644); err != nil {
		t.Fatalf("write linked wasm: %v", err)
	}
	if err := os.Symlink(filepath.Join(external, "text"), filepath.Join(root, "text")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	chains, digests, err := loadRecipeChains(context.Background(), root, options{})
	if err != nil {
		t.Fatalf("loadRecipeChains error: %v", err)
	}
	t.Cleanup(func() {
		closePipelines(context.Background(), chains)
	})

	if _, ok := chains["text/markdown"]; !ok {
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
		specs, err := parseModuleSpecs([]string{
			"examples/rgba/color-halftone.wasm",
			"?max_radius=2.0",
			"examples/rgba/brightness.wasm",
			"?brightness=0.2",
		}, "image")
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
		if _, err := parseModuleSpecs([]string{"?max_radius=2.0"}, "image"); err == nil {
			t.Fatal("expected error for query before module")
		}
	})

	t.Run("empty query is error", func(t *testing.T) {
		if _, err := parseModuleSpecs([]string{"examples/rgba/brightness.wasm", "?"}, "image"); err == nil {
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

func TestLoadFormModulesSupportsSymlinkedWasmAndIgnoresNonWasmSymlink(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()

	wasmBytes, err := os.ReadFile(filepath.Join("examples", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	externalWasm := filepath.Join(external, "contact.wasm")
	if err := os.WriteFile(externalWasm, wasmBytes, 0o644); err != nil {
		t.Fatalf("write external wasm: %v", err)
	}
	externalText := filepath.Join(external, "commonmark-spec-0.31.2.txt")
	if err := os.WriteFile(externalText, []byte("spec"), 0o644); err != nil {
		t.Fatalf("write external text: %v", err)
	}

	if err := os.Symlink(externalWasm, filepath.Join(root, "contact.wasm")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if err := os.Symlink(externalText, filepath.Join(root, "commonmark-spec-0.31.2.txt")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	modules, digests, err := loadFormModules(root)
	if err != nil {
		t.Fatalf("loadFormModules error: %v", err)
	}
	if len(modules) != 1 {
		t.Fatalf("module count=%d, want 1", len(modules))
	}
	if len(digests) != 1 {
		t.Fatalf("digest count=%d, want 1", len(digests))
	}
	if !bytes.Equal(modules["contact"], wasmBytes) {
		t.Fatalf("contact module bytes mismatch")
	}
}

func TestLoadComponentAssets(t *testing.T) {
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

	assets, requestPaths, err := loadComponentAssets(root)
	if err != nil {
		t.Fatalf("loadComponentAssets error: %v", err)
	}
	if len(assets) != 2 {
		t.Fatalf("asset count=%d, want 2", len(assets))
	}
	if len(requestPaths) != 2 {
		t.Fatalf("request path count=%d, want 2", len(requestPaths))
	}
	if !bytes.Equal(assets["/components/contact.wasm"].body, wasmBytes) {
		t.Fatalf("contact component bytes mismatch")
	}
	if got := assets["/components/contact.wasm"].contentType; got != "application/wasm" {
		t.Fatalf("content type=%q, want application/wasm", got)
	}
	if !bytes.Equal(assets["/components/nested/signup.wasm"].body, wasmBytes) {
		t.Fatalf("nested/signup component bytes mismatch")
	}
}

func TestLoadComponentAssetsSupportsSymlinkedWasmAndIgnoresNonWasmSymlink(t *testing.T) {
	root := t.TempDir()
	external := t.TempDir()

	wasmBytes, err := os.ReadFile(filepath.Join("examples", "hello.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}
	externalWasm := filepath.Join(external, "contact.wasm")
	if err := os.WriteFile(externalWasm, wasmBytes, 0o644); err != nil {
		t.Fatalf("write external wasm: %v", err)
	}
	externalText := filepath.Join(external, "commonmark-spec-0.31.2.txt")
	if err := os.WriteFile(externalText, []byte("spec"), 0o644); err != nil {
		t.Fatalf("write external text: %v", err)
	}

	if err := os.Symlink(externalWasm, filepath.Join(root, "contact.wasm")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	if err := os.Symlink(externalText, filepath.Join(root, "commonmark-spec-0.31.2.txt")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	assets, requestPaths, err := loadComponentAssets(root)
	if err != nil {
		t.Fatalf("loadComponentAssets error: %v", err)
	}
	if len(assets) != 1 {
		t.Fatalf("asset count=%d, want 1", len(assets))
	}
	if len(requestPaths) != 1 {
		t.Fatalf("request path count=%d, want 1", len(requestPaths))
	}
	if !bytes.Equal(assets["/components/contact.wasm"].body, wasmBytes) {
		t.Fatalf("contact component bytes mismatch")
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
	formComponents := map[string][]byte{
		"contact": []byte{0x00, 0x61, 0x73, 0x6d},
	}
	formDigests := map[string][32]byte{
		"contact": sha256.Sum256(formComponents["contact"]),
	}

	out, digests, err := injectQIPFormRuntime(htmlBody, formComponents, formDigests)
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

func TestInjectQIPEditRuntime(t *testing.T) {
	htmlBody := []byte(`<html><body><h1>Page</h1><qip-edit><source src="/components/utf8/hello.wasm" type="application/wasm"></source><textarea name="input"></textarea><output name="output"></output></qip-edit></body></html>`)
	out := injectQIPEditRuntime(htmlBody)
	if !bytes.Contains(out, []byte(`<script type="module">`)) {
		t.Fatalf("expected inline module script injection")
	}
	if !bytes.Contains(out, []byte(`customElements.define("qip-edit"`)) {
		t.Fatalf("expected qip-edit custom element runtime")
	}
	scriptIdx := strings.Index(string(out), `<script type="module">`)
	bodyCloseIdx := strings.Index(strings.ToLower(string(out)), `</body>`)
	if scriptIdx == -1 || bodyCloseIdx == -1 || scriptIdx > bodyCloseIdx {
		t.Fatalf("expected script to be injected before </body>")
	}
}

func TestInjectQIPEditRuntimeNoTag(t *testing.T) {
	htmlBody := []byte(`<html><body><h1>Page</h1><p>No preview.</p></body></html>`)
	out := injectQIPEditRuntime(htmlBody)
	if !bytes.Equal(out, htmlBody) {
		t.Fatalf("expected html body to remain unchanged when no qip-edit tags are present")
	}
}

func TestInjectQIPPlayRuntime(t *testing.T) {
	htmlBody := []byte(`<html><body><h1>Play</h1><qip-play><source src="/components/interactive/tile-world-12x12.wasm" type="application/wasm"></source></qip-play></body></html>`)
	out := injectQIPPlayRuntime(htmlBody)
	if !bytes.Contains(out, []byte(`<script type="module">`)) {
		t.Fatalf("expected inline module script injection")
	}
	if !bytes.Contains(out, []byte(`customElements.define("qip-play"`)) {
		t.Fatalf("expected qip-play custom element runtime")
	}
	scriptIdx := strings.Index(string(out), `<script type="module">`)
	bodyCloseIdx := strings.Index(strings.ToLower(string(out)), `</body>`)
	if scriptIdx == -1 || bodyCloseIdx == -1 || scriptIdx > bodyCloseIdx {
		t.Fatalf("expected script to be injected before </body>")
	}
}

func TestInjectQIPPlayRuntimeNoTag(t *testing.T) {
	htmlBody := []byte(`<html><body><h1>Page</h1><p>No play.</p></body></html>`)
	out := injectQIPPlayRuntime(htmlBody)
	if !bytes.Equal(out, htmlBody) {
		t.Fatalf("expected html body to remain unchanged when no qip-play tags are present")
	}
}

func TestTryRunInteractiveModuleFirstFrame(t *testing.T) {
	handled, bmp, err := tryRunInteractiveModuleFirstFrame(context.Background(), moduleSpec{
		path:     "modules/interactive/tile-world-12x12.wasm",
		uniforms: map[string]string{},
	}, options{}, 2000)
	if err != nil {
		t.Fatalf("tryRunInteractiveModuleFirstFrame: %v", err)
	}
	if !handled {
		t.Fatal("expected interactive module to be handled")
	}
	w, h, err := qinternal.GetBMPDimensions(bmp)
	if err != nil {
		t.Fatalf("output was not BMP: %v", err)
	}
	if w != 288 || h != 288 {
		t.Fatalf("bmp dimensions=%dx%d, want 288x288", w, h)
	}
}

func TestBuildAndExtractMinimalWARCResponseRecord(t *testing.T) {
	original := qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusAccepted,
		Header: http.Header{
			"Content-Type": []string{"text/html; charset=utf-8"},
			"X-Test":       []string{"one", "two"},
		},
		Body: []byte("<h1>Hello</h1>"),
	}

	record, err := buildMinimalWARCResponseRecord("http://qip.local/docs", original)
	if err != nil {
		t.Fatalf("buildMinimalWARCResponseRecord: %v", err)
	}

	parsed, err := extractFirstWARCResponseRecord(record)
	if err != nil {
		t.Fatalf("extractFirstWARCResponseRecord: %v", err)
	}
	if parsed.StatusCode != original.StatusCode {
		t.Fatalf("status=%d, want %d", parsed.StatusCode, original.StatusCode)
	}
	if !bytes.Equal(parsed.Body, original.Body) {
		t.Fatalf("body=%q, want %q", parsed.Body, original.Body)
	}
	if got := parsed.Header.Get("Content-Type"); got != "text/html; charset=utf-8" {
		t.Fatalf("content-type=%q, want text/html; charset=utf-8", got)
	}
	if got := strings.Join(parsed.Header.Values("X-Test"), ","); got != "one,two" {
		t.Fatalf("x-test=%q, want one,two", got)
	}
}

func TestExtractFirstWARCResponseRecordSkipsNonResponseRecords(t *testing.T) {
	first, err := buildMinimalWARCResponseRecord("http://qip.local/ignored", qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
		Body:       []byte("ignored"),
	})
	if err != nil {
		t.Fatalf("build first record: %v", err)
	}
	first = bytes.Replace(first, []byte("WARC-Type: response"), []byte("WARC-Type: request "), 1)

	secondBody := []byte("kept")
	second, err := buildMinimalWARCResponseRecord("http://qip.local/kept", qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusCreated,
		Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
		Body:       secondBody,
	})
	if err != nil {
		t.Fatalf("build second record: %v", err)
	}

	parsed, err := extractFirstWARCResponseRecord(append(first, second...))
	if err != nil {
		t.Fatalf("extractFirstWARCResponseRecord: %v", err)
	}
	if parsed.StatusCode != http.StatusCreated {
		t.Fatalf("status=%d, want %d", parsed.StatusCode, http.StatusCreated)
	}
	if !bytes.Equal(parsed.Body, secondBody) {
		t.Fatalf("body=%q, want %q", parsed.Body, secondBody)
	}
}

func TestExtractWARCResponseRecordByTargetURI(t *testing.T) {
	first, err := buildMinimalWARCResponseRecord("http://qip.local/docs", qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
		Body:       []byte("docs"),
	})
	if err != nil {
		t.Fatalf("build first record: %v", err)
	}
	second, err := buildMinimalWARCResponseRecord("http://qip.local/docs/security-model", qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
		Body:       []byte("security"),
	})
	if err != nil {
		t.Fatalf("build second record: %v", err)
	}

	parsed, err := extractWARCResponseRecordByTargetURI(append(first, second...), "http://qip.local/docs/security-model")
	if err != nil {
		t.Fatalf("extractWARCResponseRecordByTargetURI: %v", err)
	}
	if !bytes.Equal(parsed.Body, []byte("security")) {
		t.Fatalf("body=%q, want security", parsed.Body)
	}
}

func TestContextualWARCRequestPaths(t *testing.T) {
	tests := []struct {
		requestPath string
		want        []string
	}{
		{"/", []string{"/"}},
		{"/docs", []string{"/"}},
		{"/docs/security-model", []string{"/", "/docs"}},
		{"/docs/api/foo", []string{"/", "/docs", "/docs/api"}},
	}
	for _, tt := range tests {
		got := contextualWARCRequestPaths(tt.requestPath)
		if !reflect.DeepEqual(got, tt.want) {
			t.Fatalf("contextualWARCRequestPaths(%q)=%v, want %v", tt.requestPath, got, tt.want)
		}
	}
}
