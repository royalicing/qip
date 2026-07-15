package main

import (
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestBuildRouteListEntries(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/about":        {FilePath: "docs/about.md", SourceMIME: "text/markdown"},
				"/about/":       {FilePath: "docs/about.md", SourceMIME: "text/markdown"},
				"/images/logo":  {FilePath: "docs/images/logo.png", SourceMIME: "image/png"},
				"/images/logo/": {FilePath: "docs/images/logo.png", SourceMIME: "image/png"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
		},
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
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/how-it-works":     {FilePath: "site/how-it-works.uri", SourceMIME: "text/uri-list"},
				"/how-it-works.uri": {FilePath: "site/how-it-works.uri", SourceMIME: "text/uri-list"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
		},
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

	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/how-it-works":     {FilePath: redirectPath, SourceMIME: "text/uri-list"},
				"/how-it-works.uri": {FilePath: redirectPath, SourceMIME: "text/uri-list"},
			},
			routeOptions:  qinternal.DefaultRouteOptions(),
			recipeDigests: map[string][][32]byte{},
		},
		recipeChains: map[string]*qinternal.Pipeline{},
	}
	stateSlot := newRouterServerStateSlot(state)
	handler := newDevRequestHandler("test", stateSlot, nil, nil, qinternal.DefaultRouteOptions(), routeHandlerTimeouts{})

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
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/guide":    {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
				"/guide.md": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
		},
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
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/guide":    {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
				"/guide.md": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
		},
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
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/guide": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
			componentAssets: map[string]componentAsset{
				"/components/bytes/base64-encode.wasm": {contentType: "application/wasm"},
			},
			componentRequestPaths: []string{"/components/bytes/base64-encode.wasm"},
		},
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
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
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
		},
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
