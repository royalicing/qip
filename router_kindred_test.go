package main

import (
	"context"
	"net/http"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestResolveKindredStaticRouteOnlyReturnsRawNonHTMLFiles(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/raw.txt":   {FilePath: "raw", SourceMIME: "text/plain"},
				"/page.html": {FilePath: "html", SourceMIME: "text/html"},
				"/generated": {FilePath: "markdown", SourceMIME: "text/markdown"},
				"/redirect":  {FilePath: "redirect", SourceMIME: "text/uri-list"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
			componentAssets: map[string]componentAsset{
				"/components/tool.wasm": {body: []byte("wasm"), contentType: "application/wasm"},
			},
			contentRead: func(_ context.Context, route qinternal.ContentRoute) ([]byte, error) {
				return []byte(route.FilePath), nil
			},
		},
		recipeChains: map[string]*qinternal.Pipeline{
			"text/markdown": &qinternal.Pipeline{},
		},
	}

	for _, requestPath := range []string{"/raw.txt", "/redirect", "/components/tool.wasm"} {
		response, ok, err := resolveKindredStaticRoute(context.Background(), state, requestPath)
		if err != nil || !ok || response.StatusCode != http.StatusOK {
			t.Fatalf("resolve %q: ok=%v status=%d err=%v", requestPath, ok, response.StatusCode, err)
		}
	}
	for _, requestPath := range []string{"/page.html", "/generated", "/missing"} {
		_, ok, err := resolveKindredStaticRoute(context.Background(), state, requestPath)
		if err != nil || ok {
			t.Fatalf("resolve %q: ok=%v err=%v, want excluded", requestPath, ok, err)
		}
	}
}
