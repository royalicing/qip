package qinternal

import (
	"reflect"
	"testing"
)

func TestNormalizeComplyArgs(t *testing.T) {
	in := []string{
		"impl.wasm",
		"--with",
		"a.wasm",
		"--with",
		"b.wasm",
		"--seed",
		"500",
	}
	got := normalizeComplyArgs(in)
	want := []string{
		"--with",
		"a.wasm",
		"--with",
		"b.wasm",
		"--seed",
		"500",
		"impl.wasm",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}

func TestNormalizeFormArgs(t *testing.T) {
	in := []string{"module.wasm", "-v"}
	got := normalizeFormArgs(in)
	want := []string{"-v", "module.wasm"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}

func TestNormalizeFlagArgsPreservesDoubleDash(t *testing.T) {
	in := []string{"module.wasm", "--", "--not-a-flag"}
	got := NormalizeFlagArgs(in, map[string]struct{}{
		"--timeout-ms": {},
	})
	want := []string{"--", "module.wasm", "--not-a-flag"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}
