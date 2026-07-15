package qinternal

import (
	"reflect"
	"testing"
)

func TestPrescanHTMLSourcePaths(t *testing.T) {
	body := []byte(`
		<img src="/images/hero.png?width=2#preview">
		<script SRC='../app.js'></script>
		<custom-element src=/components/tool.wasm></custom-element>
		<img src="/images/hero.png">
		<img src="https://cdn.example/image.png">
		<img src="data:image/png;base64,AA==">
		<!-- <img src="/ignored-comment.png"> -->
		<script>const example = '</scripture><img src="/ignored-script.png">';</script>
		<iframe src="/frame"><img src="/ignored-fallback.png"></iframe>
	`)
	want := []string{"/images/hero.png", "/app.js", "/components/tool.wasm", "/frame"}
	if got := prescanHTMLSourcePaths(body, "/docs/page"); !reflect.DeepEqual(got, want) {
		t.Fatalf("prescanHTMLSourcePaths()=%v, want %v", got, want)
	}
}
