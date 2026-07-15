package qinternal

import (
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func TestKindredRoutes(t *testing.T) {
	htmlResponse := func(body string) InProcessHTTPResponse {
		return InProcessHTTPResponse{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"text/html; charset=utf-8"}}, Body: []byte(body)}
	}
	staticResponse := func(contentType, body string) InProcessHTTPResponse {
		return InProcessHTTPResponse{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{contentType}}, Body: []byte(body)}
	}

	page := htmlResponse(`<img src="/assets/hero.png"><script src="../app.js"></script><iframe src="/other-page"></iframe><img src="/generated.css"><source src="/components/tool.wasm"><img src="/assets/hero.png?again=1">`)
	parents := map[string]InProcessHTTPResponse{"/": htmlResponse("home"), "/docs": htmlResponse("docs")}
	static := map[string]InProcessHTTPResponse{
		"/assets/hero.png":      staticResponse("image/png", "png"),
		"/app.js":               staticResponse("text/javascript", "js"),
		"/other-page":           htmlResponse("other"),
		"/components/tool.wasm": staticResponse("application/wasm", "wasm"),
	}
	routes, err := KindredRoutes(
		"/docs/page",
		page,
		func(requestPath string) (InProcessHTTPResponse, bool, error) {
			response, ok := parents[requestPath]
			return response, ok, nil
		},
		func(requestPath string) (InProcessHTTPResponse, bool, error) {
			response, ok := static[requestPath]
			return response, ok, nil
		},
	)
	if err != nil {
		t.Fatalf("KindredRoutes: %v", err)
	}
	got := make([]string, 0, len(routes))
	for _, route := range routes {
		got = append(got, route.RequestPath)
	}
	want := []string{"/", "/docs", "/assets/hero.png", "/app.js", "/components/tool.wasm", "/docs/page"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("route paths=%v, want %v", got, want)
	}
}

func TestKindredRoutesDoesNotScanNonHTML(t *testing.T) {
	response := InProcessHTTPResponse{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"text/plain"}}, Body: []byte(`<img src="/not-an-html-reference.png">`)}
	staticCalls := 0
	routes, err := KindredRoutes("/plain.txt", response, nil, func(string) (InProcessHTTPResponse, bool, error) {
		staticCalls++
		return InProcessHTTPResponse{}, false, nil
	})
	if err != nil {
		t.Fatalf("KindredRoutes: %v", err)
	}
	if staticCalls != 0 {
		t.Fatalf("static resolver called %d times, want 0", staticCalls)
	}
	if len(routes) != 1 || routes[0].RequestPath != "/plain.txt" {
		t.Fatalf("routes=%v, want only requested response", routes)
	}
}

func TestKindredRoutesLimitsSourceReferences(t *testing.T) {
	var body strings.Builder
	for i := 0; i <= maxKindredStaticRoutes; i++ {
		fmt.Fprintf(&body, `<img src="/asset-%d.bin">`, i)
	}
	response := InProcessHTTPResponse{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"text/html"}}, Body: []byte(body.String())}
	_, err := KindredRoutes("/page", response, nil, func(string) (InProcessHTTPResponse, bool, error) {
		return InProcessHTTPResponse{}, false, nil
	})
	if err == nil || !strings.Contains(err.Error(), "more than 256") {
		t.Fatalf("error=%v, want Kindred Route limit error", err)
	}
}

func TestKindredParentRoutePaths(t *testing.T) {
	tests := []struct {
		requestPath string
		want        []string
	}{
		{"/", []string{"/"}},
		{"/docs", []string{"/"}},
		{"/docs/security-model", []string{"/", "/docs"}},
		{"/docs/api/foo", []string{"/", "/docs", "/docs/api"}},
	}
	for _, tt := range tests {
		if got := kindredParentRoutePaths(tt.requestPath); !reflect.DeepEqual(got, tt.want) {
			t.Fatalf("kindredParentRoutePaths(%q)=%v, want %v", tt.requestPath, got, tt.want)
		}
	}
}
