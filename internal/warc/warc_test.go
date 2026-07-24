package warc

import (
	"bytes"
	"net/http"
	"testing"
)

func TestBuildHTTPResponseRecordIsDeterministicAndValid(t *testing.T) {
	headers := http.Header{
		"Content-Type":   []string{"text/plain; charset=utf-8"},
		"Content-Length": []string{"999"},
		"X-Extension":    []string{"kept"},
	}
	first, err := BuildHTTPResponseRecord("http://qip.local/a", http.StatusOK, headers, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildHTTPResponseRecord("http://qip.local/a", http.StatusOK, headers, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("WARC response record is not reproducible")
	}
	if err := ValidateArchive(first); err != nil {
		t.Fatalf("ValidateArchive: %v", err)
	}
	for _, want := range [][]byte{
		[]byte("WARC/1.1\r\n"),
		[]byte("WARC-Date: " + CaptureTime + "\r\n"),
		[]byte("WARC-Record-ID: <urn:uuid:"),
		[]byte("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"),
		[]byte("\r\nhello\r\n\r\n"),
		[]byte("X-Extension: kept\r\n"),
	} {
		if !bytes.Contains(first, want) {
			t.Fatalf("record is missing %q", want)
		}
	}
}

func TestValidateArchiveRejectsMissingMandatoryFields(t *testing.T) {
	archive := []byte("WARC/1.1\r\nWARC-Type: response\r\nContent-Length: 0\r\n\r\n\r\n\r\n")
	if err := ValidateArchive(archive); err == nil {
		t.Fatal("expected missing mandatory field error")
	}
}
