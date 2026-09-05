package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestBuildMultipartFormInput(t *testing.T) {
	directory := t.TempDir()
	filePath := filepath.Join(directory, "component.wasm")
	fileBody := []byte{0x00, 0x61, 0x73, 0x6d, 0xff}
	if err := os.WriteFile(filePath, fileBody, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	actual, contentType, err := buildMultipartFormInput(
		[]string{"mode=step", "component=@" + filePath},
		strings.NewReader("unused"),
	)
	if err != nil {
		t.Fatalf("buildMultipartFormInput: %v", err)
	}
	if contentType != canonicalFormContentType {
		t.Fatalf("content type=%q, want %q", contentType, canonicalFormContentType)
	}

	var expected bytes.Buffer
	expected.WriteString("--" + canonicalFormBoundary + "\r\n")
	expected.WriteString("Content-Disposition: form-data; name=\"mode\"\r\n\r\nstep\r\n")
	expected.WriteString("--" + canonicalFormBoundary + "\r\n")
	expected.WriteString("Content-Disposition: form-data; name=\"component\"; filename=\"component.wasm\"\r\n")
	expected.WriteString("Content-Type: application/octet-stream\r\n\r\n")
	expected.Write(fileBody)
	expected.WriteString("\r\n--" + canonicalFormBoundary + "--\r\n")
	if !bytes.Equal(actual, expected.Bytes()) {
		t.Fatalf("multipart bytes differ\nactual:   %q\nexpected: %q", actual, expected.Bytes())
	}
}

func TestBuildMultipartFormInputFromStdin(t *testing.T) {
	actual, _, err := buildMultipartFormInput([]string{"component=@-"}, bytes.NewReader([]byte{0x00, 0xff}))
	if err != nil {
		t.Fatalf("buildMultipartFormInput: %v", err)
	}
	expected := append([]byte(
		"--"+canonicalFormBoundary+"\r\n"+
			"Content-Disposition: form-data; name=\"component\"; filename=\"-\"\r\n"+
			"Content-Type: application/octet-stream\r\n\r\n",
	), 0x00, 0xff)
	expected = append(expected, []byte("\r\n--"+canonicalFormBoundary+"--\r\n")...)
	if !bytes.Equal(actual, expected) {
		t.Fatalf("multipart stdin bytes differ\nactual:   %q\nexpected: %q", actual, expected)
	}
}

func TestBuildMultipartFormInputUsesFileLoader(t *testing.T) {
	body := append(append([]byte{}, canonicalWasmHeader...), 0x01, 0x02)
	loadedPath := ""
	actual, _, err := buildMultipartFormInputWithFileLoader(
		[]string{"component=@text/example.wasm"},
		strings.NewReader("unused"),
		func(path string) ([]byte, error) {
			loadedPath = path
			return body, nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if loadedPath != "text/example.wasm" {
		t.Fatalf("loaded path=%q", loadedPath)
	}
	if !bytes.Contains(actual, body) || !bytes.Contains(actual, []byte(`filename="example.wasm"`)) {
		t.Fatalf("multipart form does not contain loaded file: %q", actual)
	}
}

func TestMultipartWasmHeaderValidationIsLightweight(t *testing.T) {
	if err := validateMultipartWasmHeader(append(append([]byte{}, canonicalWasmHeader...), 0xff), "example.wasm"); err != nil {
		t.Fatalf("header-only validation rejected body: %v", err)
	}
	for _, body := range [][]byte{nil, []byte("not Wasm"), {0x00, 0x61, 0x73, 0x6d, 0x02, 0x00, 0x00, 0x00}} {
		if err := validateMultipartWasmHeader(body, "example.wasm"); err == nil || !strings.Contains(err.Error(), "WebAssembly 1.0 header") {
			t.Fatalf("body=%x error=%v", body, err)
		}
	}
}

func TestResolveMultipartFormFileKeepsExistingLocalBytesOpaque(t *testing.T) {
	path := filepath.Join(t.TempDir(), "malformed.wasm")
	want := []byte("intentionally malformed")
	if err := os.WriteFile(path, want, 0o644); err != nil {
		t.Fatal(err)
	}
	body, err := resolveMultipartFormFile(path, []qinternal.ComponentHost{{Origin: "https://unused.example"}})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(body, want) {
		t.Fatalf("body=%q, want %q", body, want)
	}
}

func TestMultipartFormInputRejectsAmbiguousOrUnsupportedValues(t *testing.T) {
	marker := "before\r\n--" + canonicalFormBoundary + "\r\nafter"
	tests := []struct {
		values []string
		stdin  string
		want   string
	}{
		{[]string{"missing-equals"}, "", "requires <name=value>"},
		{[]string{"=empty-name"}, "", "requires <name=value>"},
		{[]string{"component=@"}, "", "empty file path"},
		{[]string{"one=@-", "two=@-"}, "", "only one -F field"},
		{[]string{"component=@-"}, marker, "contains the multipart boundary"},
	}
	for _, test := range tests {
		_, _, err := buildMultipartFormInput(test.values, strings.NewReader(test.stdin))
		if err == nil || !strings.Contains(err.Error(), test.want) {
			t.Fatalf("values=%v error=%v, want substring %q", test.values, err, test.want)
		}
	}
}

func TestCanonicalFormFilenameUsesOnlyFinalSegment(t *testing.T) {
	for input, expected := range map[string]string{
		"../parent/directory/foo.wasm": `foo.wasm`,
		`..\parent\directory\foo.wasm`: `foo.wasm`,
	} {
		actual, err := canonicalFormFilename(input)
		if err != nil {
			t.Fatalf("canonicalFormFilename(%q): %v", input, err)
		}
		if !reflect.DeepEqual(actual, expected) {
			t.Fatalf("canonicalFormFilename(%q)=%q, want %q", input, actual, expected)
		}
	}
}

func TestParseRunCommandArgsRejectsRawAndMultipartInput(t *testing.T) {
	_, err := parseRunCommandArgs([]string{"-i", "input.bin", "-F", "component=@component.wasm", "components/bytes/identity.wasm"}, "run")
	if err == nil || !strings.Contains(err.Error(), "-F and -i are mutually exclusive") {
		t.Fatalf("error=%v, want mutual-exclusion error", err)
	}
}

func TestParseRunCommandArgsAcceptsMultipartAfterComponent(t *testing.T) {
	config, err := parseRunCommandArgs([]string{"components/bytes/identity.wasm", "--form", "mode=step"}, "run")
	if err != nil {
		t.Fatalf("parseRunCommandArgs: %v", err)
	}
	if !reflect.DeepEqual([]string(config.formValues), []string{"mode=step"}) {
		t.Fatalf("form values=%v", config.formValues)
	}
	if len(config.componentInvocations) != 1 || config.componentInvocations[0].Source != "components/bytes/identity.wasm" {
		t.Fatalf("component invocations=%v", config.componentInvocations)
	}
}

func TestParseRunCommandArgsMultipartAliasesAccumulate(t *testing.T) {
	config, err := parseRunCommandArgs([]string{"-F", "mode=step", "--form", "component=@-", "components/bytes/identity.wasm"}, "run")
	if err != nil {
		t.Fatalf("parseRunCommandArgs: %v", err)
	}
	if !reflect.DeepEqual([]string(config.formValues), []string{"mode=step", "component=@-"}) {
		t.Fatalf("form values=%v", config.formValues)
	}
}
