package qinternal

import (
	"strings"
	"testing"
)

func TestBuildViewSourceIndexHTMLIncludesComponents(t *testing.T) {
	html := string(BuildViewSourceIndexHTML(
		[]RecipeSourceAsset{
			{RequestPath: "/view-source/recipes/text/markdown/10-markdown-basic.zig"},
		},
		[]string{"/guide.md"},
		[]string{
			"/components/utf8/trim.wasm",
			"/components/utf8/trim.wasm",
			"/not-components/ignored.wasm",
		},
		[]RecipeSourceAsset{
			{RequestPath: "/view-source/components/utf8/trim.zig"},
			{RequestPath: "/view-source/components/utf8/styles.css"},
			{RequestPath: "/view-source/components/utf8/trim.wasm"},
			{RequestPath: "/view-source/recipes/ignored.zig"},
		},
	))

	if !strings.Contains(html, "<h2>Components</h2>") {
		t.Fatalf("missing components heading: %q", html)
	}
	contentPos := strings.Index(html, "<h2>Content</h2>")
	recipesPos := strings.Index(html, "<h2>Recipes</h2>")
	if contentPos < 0 || recipesPos < 0 || contentPos > recipesPos {
		t.Fatalf("expected Content section before Recipes section: %q", html)
	}
	if got := strings.Count(html, "<h2>Components</h2>"); got != 1 {
		t.Fatalf("components heading count=%d, want 1", got)
	}
	if !strings.Contains(html, "href=\"/components/utf8/trim.wasm\"") {
		t.Fatalf("missing component href: %q", html)
	}
	if strings.Contains(html, "href=\"/not-components/ignored.wasm\"") {
		t.Fatalf("unexpected non-component href: %q", html)
	}
	if got := strings.Count(html, "href=\"/components/utf8/trim.wasm\""); got != 1 {
		t.Fatalf("component href count=%d, want 1", got)
	}
	if strings.Contains(html, "<h2>Component Sources</h2>") {
		t.Fatalf("unexpected component sources heading: %q", html)
	}
	if !strings.Contains(html, "href=\"/view-source/components/utf8/trim.zig\"") {
		t.Fatalf("missing component source href: %q", html)
	}
	if !strings.Contains(html, "href=\"/view-source/components/utf8/styles.css\"") {
		t.Fatalf("missing component source css href: %q", html)
	}
	if strings.Contains(html, "href=\"/view-source/components/utf8/trim.wasm\"") {
		t.Fatalf("expected runtime wasm href to be preferred over view-source wasm href: %q", html)
	}
	if strings.Contains(html, "href=\"/view-source/recipes/ignored.zig\"") {
		t.Fatalf("unexpected non-component source href: %q", html)
	}
}
