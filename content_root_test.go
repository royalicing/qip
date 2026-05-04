package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"path"
	"strings"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func pktLine(lines ...string) []byte {
	var b strings.Builder
	for _, line := range lines {
		lineLen := len(line) + 4
		b.WriteString(fmt.Sprintf("%04x", lineLen))
		b.WriteString(line)
	}
	b.WriteString("0000")
	return []byte(b.String())
}

func TestParseGitHubContentRoot(t *testing.T) {
	t.Run("valid repo root", func(t *testing.T) {
		spec, ok, err := parseGitHubContentRoot("github:cool-calm/collected-press")
		if err != nil {
			t.Fatalf("parseGitHubContentRoot: %v", err)
		}
		if !ok {
			t.Fatal("expected github root")
		}
		if spec.Owner != "cool-calm" || spec.Repo != "collected-press" || spec.Subdir != "" {
			t.Fatalf("spec=%+v", spec)
		}
	})

	t.Run("valid with subdir", func(t *testing.T) {
		spec, ok, err := parseGitHubContentRoot("github:cool-calm/collected-press/site/docs")
		if err != nil {
			t.Fatalf("parseGitHubContentRoot: %v", err)
		}
		if !ok {
			t.Fatal("expected github root")
		}
		if spec.Subdir != "site/docs" {
			t.Fatalf("subdir=%q, want %q", spec.Subdir, "site/docs")
		}
	})

	t.Run("non github input", func(t *testing.T) {
		_, ok, err := parseGitHubContentRoot("./site")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if ok {
			t.Fatal("expected local input")
		}
	})

	t.Run("invalid missing owner repo", func(t *testing.T) {
		_, ok, err := parseGitHubContentRoot("github:")
		if !ok {
			t.Fatal("expected github parser to claim input")
		}
		if err == nil {
			t.Fatal("expected error")
		}
	})
}

func TestParseHeadFromPktLines(t *testing.T) {
	sha := "0123456789012345678901234567890123456789"
	data := pktLine(
		"# service=git-upload-pack\n",
		sha+" HEAD\x00symref=HEAD:refs/heads/main agent=git/github\n",
	)
	gotSHA, gotRef, ok := parseHeadFromPktLines(data)
	if !ok {
		t.Fatal("expected head sha")
	}
	if gotSHA != sha {
		t.Fatalf("sha=%q, want %q", gotSHA, sha)
	}
	if gotRef != "refs/heads/main" {
		t.Fatalf("headRef=%q, want %q", gotRef, "refs/heads/main")
	}
}

func TestLoadContentRoutesAndReaderFromGitHub(t *testing.T) {
	sha := "89abcdef0123456789abcdef0123456789abcdef"
	files := map[string][]byte{
		"site/index.md":        []byte("# Hello\n"),
		"site/docs/start.md":   []byte("## Start\n"),
		"site/assets/logo.png": []byte{0x89, 0x50, 0x4e, 0x47},
	}

	baseURL := "https://example.local"
	client := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			status := http.StatusNotFound
			body := []byte("not found")
			contentType := "text/plain"

			switch {
			case strings.HasSuffix(r.URL.Path, "/info/refs"):
				if got := r.URL.Query().Get("service"); got != "git-upload-pack" {
					status = http.StatusBadRequest
					body = []byte("missing service")
					break
				}
				status = http.StatusOK
				body = pktLine(
					"# service=git-upload-pack\n",
					sha+" HEAD\x00symref=HEAD:refs/heads/main agent=git/github\n",
				)
			case strings.HasPrefix(r.URL.Path, "/repos/cool-calm/collected-press/git/trees/"):
				if got := r.URL.Query().Get("recursive"); got != "1" {
					status = http.StatusBadRequest
					body = []byte("missing recursive")
					break
				}
				status = http.StatusOK
				contentType = "application/json"
				body = []byte(`{"tree":[{"path":"site/index.md","type":"blob"},{"path":"site/docs/start.md","type":"blob"},{"path":"site/assets/logo.png","type":"blob"},{"path":"README.md","type":"blob"}],"truncated":false}`)
			case strings.HasPrefix(r.URL.Path, "/cool-calm/collected-press/"):
				parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/cool-calm/collected-press/"), "/")
				if len(parts) < 2 {
					break
				}
				gotSHA := parts[0]
				repoPath := path.Clean(strings.Join(parts[1:], "/"))
				if gotSHA != sha {
					break
				}
				data, ok := files[repoPath]
				if !ok {
					break
				}
				status = http.StatusOK
				body = data
			}

			resp := &http.Response{
				StatusCode: status,
				Status:     fmt.Sprintf("%d %s", status, http.StatusText(status)),
				Header:     make(http.Header),
				Body:       io.NopCloser(bytes.NewReader(body)),
				Request:    r,
			}
			resp.Header.Set("Content-Type", contentType)
			return resp, nil
		}),
	}

	cfg := githubFetcherConfig{
		Client:          client,
		InfoRefsBaseURL: baseURL,
		APIBaseURL:      baseURL,
		RawBaseURL:      baseURL,
	}

	routes, reader, err := loadContentRoutesAndReaderWithConfig(
		context.Background(),
		"github:cool-calm/collected-press/site",
		qinternal.DefaultRouteOptions(),
		&cfg,
	)
	if err != nil {
		t.Fatalf("loadContentRoutesAndReaderWithConfig: %v", err)
	}

	route, ok := routes["/docs/start"]
	if !ok {
		t.Fatalf("missing route /docs/start")
	}
	if !strings.HasPrefix(route.FilePath, "github:cool-calm/collected-press@"+sha+"/") {
		t.Fatalf("unexpected route source path: %q", route.FilePath)
	}
	body, err := reader(context.Background(), route)
	if err != nil {
		t.Fatalf("reader: %v", err)
	}
	if string(body) != "## Start\n" {
		t.Fatalf("body=%q", string(body))
	}

	if _, ok := routes["/"]; !ok {
		t.Fatal("missing route /")
	}
	if route, ok := routes["/assets/logo.png"]; !ok {
		t.Fatal("missing route /assets/logo.png")
	} else if route.SourceMIME != "image/png" {
		t.Fatalf("mime=%q, want %q", route.SourceMIME, "image/png")
	}
}

type roundTripFunc func(req *http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return fn(req)
}
