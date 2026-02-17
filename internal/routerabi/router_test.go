package routerabi

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadMissingExports(t *testing.T) {
	wasm := compileWAT(t, `(module
  (memory (export "memory") 1)
  (func (export "input_ptr") (result i32) (i32.const 0))
)`)

	_, err := Load(context.Background(), wasm)
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrMissingExport) {
		t.Fatalf("expected ErrMissingExport, got: %v", err)
	}
}

func TestRouteInputCapOverflow(t *testing.T) {
	wasm := compileWAT(t, validRouterWAT(validRouterWATOptions{
		inputCap: 4,
		status:   200,
	}))

	r, err := Load(context.Background(), wasm)
	if err != nil {
		t.Fatalf("load failed: %v", err)
	}
	t.Cleanup(func() {
		_ = r.Close(context.Background())
	})

	_, err = r.Route(context.Background(), "/abc", "xy")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrInputTooLarge) {
		t.Fatalf("expected ErrInputTooLarge, got: %v", err)
	}
}

func TestRouteOutOfBoundsPtrLen(t *testing.T) {
	wasm := compileWAT(t, validRouterWAT(validRouterWATOptions{
		inputCap: 64,
		status:   200,
		etagPtr:  65535,
		etagLen:  2,
	}))

	r, err := Load(context.Background(), wasm)
	if err != nil {
		t.Fatalf("load failed: %v", err)
	}
	t.Cleanup(func() {
		_ = r.Close(context.Background())
	})

	_, err = r.Route(context.Background(), "/", "")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrOutOfBounds) {
		t.Fatalf("expected ErrOutOfBounds, got: %v", err)
	}
}

func TestRouteInvalidRedirect(t *testing.T) {
	wasm := compileWAT(t, validRouterWAT(validRouterWATOptions{
		inputCap:    64,
		status:      302,
		locationLen: 0,
	}))

	r, err := Load(context.Background(), wasm)
	if err != nil {
		t.Fatalf("load failed: %v", err)
	}
	t.Cleanup(func() {
		_ = r.Close(context.Background())
	})

	_, err = r.Route(context.Background(), "/", "")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrInvalidRedirect) {
		t.Fatalf("expected ErrInvalidRedirect, got: %v", err)
	}
}

func TestRouteDecodesDigestArrays(t *testing.T) {
	contentDigests := make([]byte, 64)
	for i := range contentDigests {
		contentDigests[i] = byte(i)
	}
	recipeDigests := make([]byte, 32)
	for i := range recipeDigests {
		recipeDigests[i] = byte(0x80 + i)
	}

	wasm := compileWAT(t, validRouterWAT(validRouterWATOptions{
		inputCap:           64,
		status:             200,
		etagPtr:            1024,
		etagLen:            3,
		contentTypePtr:     1040,
		contentTypeLen:     10,
		contentSHA256Ptr:   1100,
		contentSHA256Count: 2,
		recipeSHA256Ptr:    1200,
		recipeSHA256Count:  1,
		locationLen:        0,
		dataSegments: []string{
			`(data (i32.const 1024) "xyz")`,
			`(data (i32.const 1040) "text/plain")`,
			fmt.Sprintf(`(data (i32.const 1100) "%s")`, watBytesLiteral(contentDigests)),
			fmt.Sprintf(`(data (i32.const 1200) "%s")`, watBytesLiteral(recipeDigests)),
		},
	}))

	r, err := Load(context.Background(), wasm)
	if err != nil {
		t.Fatalf("load failed: %v", err)
	}
	t.Cleanup(func() {
		_ = r.Close(context.Background())
	})

	got, err := r.Route(context.Background(), "/", "")
	if err != nil {
		t.Fatalf("route failed: %v", err)
	}

	if got.Status != 200 {
		t.Fatalf("status: got %d want 200", got.Status)
	}
	if got.ETag != "xyz" {
		t.Fatalf("etag: got %q want %q", got.ETag, "xyz")
	}
	if got.ContentType != "text/plain" {
		t.Fatalf("content-type: got %q want %q", got.ContentType, "text/plain")
	}
	if len(got.ContentSHA256) != 2 {
		t.Fatalf("content digest count: got %d want 2", len(got.ContentSHA256))
	}
	if len(got.RecipeSHA256) != 1 {
		t.Fatalf("recipe digest count: got %d want 1", len(got.RecipeSHA256))
	}

	var wantContent0 [32]byte
	copy(wantContent0[:], contentDigests[:32])
	var wantContent1 [32]byte
	copy(wantContent1[:], contentDigests[32:64])
	var wantRecipe0 [32]byte
	copy(wantRecipe0[:], recipeDigests)

	if got.ContentSHA256[0] != wantContent0 {
		t.Fatalf("content digest 0 mismatch")
	}
	if got.ContentSHA256[1] != wantContent1 {
		t.Fatalf("content digest 1 mismatch")
	}
	if got.RecipeSHA256[0] != wantRecipe0 {
		t.Fatalf("recipe digest 0 mismatch")
	}
}

type validRouterWATOptions struct {
	inputCap           int
	status             int
	etagPtr            int
	etagLen            int
	contentTypePtr     int
	contentTypeLen     int
	contentSHA256Ptr   int
	contentSHA256Count int
	recipeSHA256Ptr    int
	recipeSHA256Count  int
	locationPtr        int
	locationLen        int
	dataSegments       []string
}

func validRouterWATOptionsDefault() validRouterWATOptions {
	return validRouterWATOptions{
		inputCap:           64,
		status:             200,
		etagPtr:            0,
		etagLen:            0,
		contentTypePtr:     0,
		contentTypeLen:     0,
		contentSHA256Ptr:   0,
		contentSHA256Count: 0,
		recipeSHA256Ptr:    0,
		recipeSHA256Count:  0,
		locationPtr:        0,
		locationLen:        1,
	}
}

func validRouterWAT(in validRouterWATOptions) string {
	base := validRouterWATOptionsDefault()
	if in.inputCap != 0 {
		base.inputCap = in.inputCap
	}
	if in.status != 0 {
		base.status = in.status
	}
	base.etagPtr = in.etagPtr
	base.etagLen = in.etagLen
	base.contentTypePtr = in.contentTypePtr
	base.contentTypeLen = in.contentTypeLen
	base.contentSHA256Ptr = in.contentSHA256Ptr
	base.contentSHA256Count = in.contentSHA256Count
	base.recipeSHA256Ptr = in.recipeSHA256Ptr
	base.recipeSHA256Count = in.recipeSHA256Count
	base.locationPtr = in.locationPtr
	base.locationLen = in.locationLen
	base.dataSegments = in.dataSegments

	return fmt.Sprintf(`(module
  (memory (export "memory") 1)
  (func (export "input_ptr") (result i32) (i32.const 0))
  (func (export "input_cap") (result i32) (i32.const %d))
  (func (export "route") (param i32 i32) (result i32) (i32.const %d))
  (func (export "etag_ptr") (result i32) (i32.const %d))
  (func (export "etag_len") (result i32) (i32.const %d))
  (func (export "content_type_ptr") (result i32) (i32.const %d))
  (func (export "content_type_len") (result i32) (i32.const %d))
  (func (export "content_sha256_ptr") (result i32) (i32.const %d))
  (func (export "content_sha256_count") (result i32) (i32.const %d))
  (func (export "recipe_sha256_ptr") (result i32) (i32.const %d))
  (func (export "recipe_sha256_count") (result i32) (i32.const %d))
  (func (export "location_ptr") (result i32) (i32.const %d))
  (func (export "location_len") (result i32) (i32.const %d))
  %s
)`,
		base.inputCap,
		base.status,
		base.etagPtr,
		base.etagLen,
		base.contentTypePtr,
		base.contentTypeLen,
		base.contentSHA256Ptr,
		base.contentSHA256Count,
		base.recipeSHA256Ptr,
		base.recipeSHA256Count,
		base.locationPtr,
		base.locationLen,
		strings.Join(base.dataSegments, "\n  "),
	)
}

func compileWAT(t *testing.T, wat string) []byte {
	t.Helper()

	wat2wasm, err := exec.LookPath("wat2wasm")
	if err != nil {
		t.Skip("wat2wasm not found in PATH")
	}

	dir := t.TempDir()
	watPath := filepath.Join(dir, "router.wat")
	wasmPath := filepath.Join(dir, "router.wasm")

	if err := os.WriteFile(watPath, []byte(wat), 0o644); err != nil {
		t.Fatalf("write wat: %v", err)
	}

	cmd := exec.Command(wat2wasm, watPath, "-o", wasmPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("wat2wasm failed: %v\n%s", err, string(out))
	}

	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read wasm: %v", err)
	}
	return wasm
}

func watBytesLiteral(b []byte) string {
	var sb strings.Builder
	for _, v := range b {
		sb.WriteString(fmt.Sprintf("\\%02x", v))
	}
	return sb.String()
}
