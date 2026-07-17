package main

import (
	"bytes"
	"crypto/sha256"
	"reflect"
	"strings"
	"testing"
)

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
