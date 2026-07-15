package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestRouterFileStateCapturesRecipeBytesWithoutCompilingThem(t *testing.T) {
	contentRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(contentRoot, "index.html"), []byte("<h1>Home</h1>"), 0o644); err != nil {
		t.Fatalf("write content: %v", err)
	}

	recipesRoot := t.TempDir()
	recipeDir := filepath.Join(recipesRoot, "text", "html")
	if err := os.MkdirAll(recipeDir, 0o755); err != nil {
		t.Fatalf("mkdir recipe: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "10-invalid.wasm"), []byte("not wasm"), 0o644); err != nil {
		t.Fatalf("write recipe: %v", err)
	}

	files, err := loadRouterFileState(
		context.Background(),
		RouterFileLayout{ContentRoot: contentRoot, RecipesRoot: recipesRoot},
		qinternal.DefaultRouteOptions(),
	)
	if err != nil {
		t.Fatalf("loadRouterFileState: %v", err)
	}
	if got := len(files.recipeFiles["text/html"]); got != 1 {
		t.Fatalf("recipe file count=%d, want 1", got)
	}
	validWasm, err := os.ReadFile(filepath.Join("examples", "hello.wasm"))
	if err != nil {
		t.Fatalf("read valid Wasm fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipeDir, "10-invalid.wasm"), validWasm, 0o644); err != nil {
		t.Fatalf("replace recipe after snapshot: %v", err)
	}

	if _, err := buildRouterServerState(context.Background(), files, options{}); err == nil {
		t.Fatal("expected server-state construction to compile the invalid bytes captured in the file snapshot")
	}
}

func TestRouterServerStateSlotSwapsCompleteGenerations(t *testing.T) {
	first := &RouterServerState{RouterFileState: &RouterFileState{
		contentRoutes: map[string]qinternal.ContentRoute{"/first": {}},
	}}
	second := &RouterServerState{RouterFileState: &RouterFileState{
		contentRoutes: map[string]qinternal.ContentRoute{"/second": {}},
	}}
	slot := newRouterServerStateSlot(first)

	if previous := slot.swap(second); previous != first {
		t.Fatalf("previous state=%p, want %p", previous, first)
	}
	slot.mu.RLock()
	current := slot.state
	slot.mu.RUnlock()
	if current != second {
		t.Fatalf("current state=%p, want %p", current, second)
	}
	if _, ok := current.contentRoutes["/second"]; !ok {
		t.Fatal("current generation does not contain its complete route state")
	}
}
