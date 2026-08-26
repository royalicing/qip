package qinternal

import (
	"context"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseComponentHostMatchesQipxGrammar(t *testing.T) {
	t.Parallel()
	tests := []struct {
		input     string
		authority string
		valid     bool
	}{
		{input: "QIP.Dev", authority: "qip.dev", valid: true},
		{input: "mirror.example:00443", authority: "mirror.example:443", valid: true},
		{input: "localhost", valid: false},
		{input: "127.0.0.1", valid: false},
		{input: "https://qip.dev", valid: false},
		{input: "qip.dev/path", valid: false},
		{input: "-qip.dev", valid: false},
		{input: "qip.dev:0", valid: false},
		{input: "qip.dev:65536", valid: false},
	}
	for _, test := range tests {
		t.Run(test.input, func(t *testing.T) {
			host, err := ParseComponentHost(test.input)
			if test.valid && err != nil {
				t.Fatalf("ParseComponentHost: %v", err)
			}
			if !test.valid && err == nil {
				t.Fatalf("ParseComponentHost unexpectedly accepted %q", test.input)
			}
			if host.Authority != test.authority {
				t.Fatalf("authority=%q, want %q", host.Authority, test.authority)
			}
		})
	}
}

func TestSameHTTPSOriginNormalizesDNSCaseAndDefaultPort(t *testing.T) {
	t.Parallel()
	parse := func(raw string) *url.URL {
		value, err := url.Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	if !sameHTTPSOrigin(parse("https://qip.dev/a"), parse("https://QIP.DEV:443/b")) {
		t.Fatal("expected equivalent HTTPS origins")
	}
	if sameHTTPSOrigin(parse("https://qip.dev/a"), parse("https://qip.dev:8443/b")) {
		t.Fatal("expected different ports to be different origins")
	}
}

func TestPlanComponentSourcesMatchesQipxOrderingAndEscaping(t *testing.T) {
	t.Parallel()
	hosts := []ComponentHost{
		{Authority: "qip.dev", Origin: "https://qip.dev"},
		{Authority: "mirror.example:8443", Origin: "https://mirror.example:8443"},
	}
	plan := PlanComponentSources("text/a b!()+.wasm", hosts)
	want := []ComponentSource{
		{Kind: "local", Path: "text/a b!()+.wasm"},
		{Kind: "https", URL: "https://qip.dev/text/a%20b!()%2B.wasm"},
		{Kind: "https", URL: "https://mirror.example:8443/text/a%20b!()%2B.wasm"},
	}
	if !reflect.DeepEqual(plan.Sources, want) {
		t.Fatalf("sources=%#v, want %#v", plan.Sources, want)
	}
}

func TestRemotelyEligibleComponentPathMatchesQipxSafetyRules(t *testing.T) {
	t.Parallel()
	valid := []string{"component.wasm", "text/markdown/component.wasm", "space name.wasm"}
	invalid := []string{"component.wat", "/component.wasm", `C:\\component.wasm`, `text\\component.wasm`, "../component.wasm", "text/./component.wasm", "text//component.wasm", "component.wasm?q", "component.wasm#x", "component.wasm\x00"}
	for _, path := range valid {
		if !RemotelyEligibleComponentPath(path) {
			t.Errorf("expected eligible: %q", path)
		}
	}
	for _, path := range invalid {
		if RemotelyEligibleComponentPath(path) {
			t.Errorf("expected ineligible: %q", path)
		}
	}
}

func TestResolveComponentSourcePrefersAndValidatesLocalFile(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, "component.wasm")
	if err := os.WriteFile(path, []byte("local"), 0o644); err != nil {
		t.Fatal(err)
	}
	labels := []string{}
	body, err := ResolveComponentSource(context.Background(), path, []ComponentHost{{Origin: "https://unused.example"}}, func(body []byte, label string) error {
		labels = append(labels, label)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "local" || !reflect.DeepEqual(labels, []string{path}) {
		t.Fatalf("body=%q labels=%v", body, labels)
	}
}

func TestResolveComponentSourceExplainsIneligibleMissingPath(t *testing.T) {
	t.Parallel()
	_, err := ResolveComponentSource(context.Background(), "../missing.wasm", []ComponentHost{{Origin: "https://qip.dev"}}, func([]byte, string) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "only missing relative paths ending in .wasm can be downloaded") {
		t.Fatalf("error=%v", err)
	}
}
