package main

import (
	"bytes"
	"net/http"
	"strings"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestBuildAndExtractMinimalWARCResponseRecord(t *testing.T) {
	original := qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusAccepted,
		Header: http.Header{
			"Content-Type": []string{"text/html; charset=utf-8"},
			"X-Test":       []string{"one", "two"},
		},
		Body: []byte("<h1>Hello</h1>"),
	}

	record, err := buildMinimalWARCResponseRecord("http://qip.local/docs", original)
	if err != nil {
		t.Fatalf("buildMinimalWARCResponseRecord: %v", err)
	}

	parsed, err := extractFirstWARCResponseRecord(record)
	if err != nil {
		t.Fatalf("extractFirstWARCResponseRecord: %v", err)
	}
	if parsed.StatusCode != original.StatusCode {
		t.Fatalf("status=%d, want %d", parsed.StatusCode, original.StatusCode)
	}
	if !bytes.Equal(parsed.Body, original.Body) {
		t.Fatalf("body=%q, want %q", parsed.Body, original.Body)
	}
	if got := parsed.Header.Get("Content-Type"); got != "text/html; charset=utf-8" {
		t.Fatalf("content-type=%q, want text/html; charset=utf-8", got)
	}
	if got := strings.Join(parsed.Header.Values("X-Test"), ","); got != "one,two" {
		t.Fatalf("x-test=%q, want one,two", got)
	}
}

func TestExtractFirstWARCResponseRecordSkipsNonResponseRecords(t *testing.T) {
	first, err := buildMinimalWARCResponseRecord("http://qip.local/ignored", qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
		Body:       []byte("ignored"),
	})
	if err != nil {
		t.Fatalf("build first record: %v", err)
	}
	first = bytes.Replace(first, []byte("WARC-Type: response"), []byte("WARC-Type: request "), 1)

	secondBody := []byte("kept")
	second, err := buildMinimalWARCResponseRecord("http://qip.local/kept", qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusCreated,
		Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
		Body:       secondBody,
	})
	if err != nil {
		t.Fatalf("build second record: %v", err)
	}

	parsed, err := extractFirstWARCResponseRecord(append(first, second...))
	if err != nil {
		t.Fatalf("extractFirstWARCResponseRecord: %v", err)
	}
	if parsed.StatusCode != http.StatusCreated {
		t.Fatalf("status=%d, want %d", parsed.StatusCode, http.StatusCreated)
	}
	if !bytes.Equal(parsed.Body, secondBody) {
		t.Fatalf("body=%q, want %q", parsed.Body, secondBody)
	}
}

func TestExtractWARCResponseRecordByTargetURI(t *testing.T) {
	first, err := buildMinimalWARCResponseRecord("http://qip.local/docs", qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
		Body:       []byte("docs"),
	})
	if err != nil {
		t.Fatalf("build first record: %v", err)
	}
	second, err := buildMinimalWARCResponseRecord("http://qip.local/docs/security-model", qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
		Body:       []byte("security"),
	})
	if err != nil {
		t.Fatalf("build second record: %v", err)
	}

	parsed, err := extractWARCResponseRecordByTargetURI(append(first, second...), "http://qip.local/docs/security-model")
	if err != nil {
		t.Fatalf("extractWARCResponseRecordByTargetURI: %v", err)
	}
	if !bytes.Equal(parsed.Body, []byte("security")) {
		t.Fatalf("body=%q, want security", parsed.Body)
	}
}
