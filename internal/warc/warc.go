package warc

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"net/textproto"
	"sort"
	"strconv"
	"strings"
)

const (
	Version     = "WARC/1.1"
	CaptureTime = "2000-01-01T00:00:00Z"
)

func BuildHTTPResponseRecord(targetURI string, statusCode int, headers http.Header, body []byte) ([]byte, error) {
	targetURI = strings.TrimSpace(targetURI)
	if targetURI == "" {
		return nil, errors.New("target URI must not be empty")
	}
	payload := buildHTTPResponsePayload(statusCode, headers, body)
	recordID := deterministicRecordID(targetURI, payload)

	var buf bytes.Buffer
	buf.WriteString(Version + "\r\n")
	buf.WriteString("WARC-Type: response\r\n")
	buf.WriteString("WARC-Target-URI: " + targetURI + "\r\n")
	buf.WriteString("WARC-Date: " + CaptureTime + "\r\n")
	buf.WriteString("WARC-Record-ID: " + recordID + "\r\n")
	buf.WriteString("Content-Type: application/http; msgtype=response\r\n")
	buf.WriteString("Content-Length: " + strconv.Itoa(len(payload)) + "\r\n\r\n")
	buf.Write(payload)
	buf.WriteString("\r\n\r\n")
	return buf.Bytes(), nil
}

func buildHTTPResponsePayload(statusCode int, source http.Header, body []byte) []byte {
	if statusCode == 0 {
		statusCode = http.StatusOK
	}
	statusText := http.StatusText(statusCode)
	if statusText == "" {
		statusText = "Status"
	}

	headers := source.Clone()
	if headers == nil {
		headers = make(http.Header)
	}
	headers.Del("Transfer-Encoding")
	headers.Set("Content-Length", strconv.Itoa(len(body)))

	keys := make([]string, 0, len(headers))
	for key := range headers {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var payload bytes.Buffer
	fmt.Fprintf(&payload, "HTTP/1.1 %d %s\r\n", statusCode, statusText)
	for _, key := range keys {
		for _, value := range headers[key] {
			payload.WriteString(key + ": " + value + "\r\n")
		}
	}
	payload.WriteString("\r\n")
	payload.Write(body)
	return payload.Bytes()
}

func deterministicRecordID(targetURI string, payload []byte) string {
	hash := sha256.New()
	hash.Write([]byte("qip:warc-response:v1\x00"))
	hash.Write([]byte(targetURI))
	hash.Write([]byte{0})
	hash.Write(payload)
	sum := hash.Sum(nil)
	raw := append([]byte(nil), sum[:16]...)
	raw[6] = (raw[6] & 0x0f) | 0x80
	raw[8] = (raw[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"<urn:uuid:%x-%x-%x-%x-%x>",
		raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16],
	)
}

func ValidateArchive(archive []byte) error {
	if len(archive) == 0 {
		return errors.New("WARC archive is empty")
	}
	cursor := 0
	recordNumber := 0
	for cursor < len(archive) {
		recordNumber++
		headerEnd := bytes.Index(archive[cursor:], []byte("\r\n\r\n"))
		if headerEnd < 0 {
			return fmt.Errorf("WARC record %d is missing its header terminator", recordNumber)
		}
		headerEnd += cursor
		lines := bytes.Split(archive[cursor:headerEnd], []byte("\r\n"))
		if len(lines) == 0 || string(lines[0]) != Version {
			return fmt.Errorf("WARC record %d must use %s", recordNumber, Version)
		}

		required := map[string]bool{
			"warc-type":      false,
			"warc-record-id": false,
			"warc-date":      false,
			"content-length": false,
		}
		contentLength := -1
		warcType := ""
		havePreviousField := false
		for _, line := range lines[1:] {
			if len(line) > 0 && (line[0] == ' ' || line[0] == '\t') {
				if !havePreviousField {
					return fmt.Errorf("WARC record %d has an orphaned continuation line", recordNumber)
				}
				continue
			}
			colon := bytes.IndexByte(line, ':')
			if colon <= 0 {
				return fmt.Errorf("WARC record %d has an invalid named field", recordNumber)
			}
			havePreviousField = true
			name := strings.ToLower(strings.TrimSpace(string(line[:colon])))
			value := strings.TrimSpace(string(line[colon+1:]))
			if _, ok := required[name]; ok {
				if required[name] {
					return fmt.Errorf("WARC record %d repeats %s", recordNumber, name)
				}
				required[name] = true
			}
			switch name {
			case "content-length":
				n, err := strconv.Atoi(value)
				if err != nil || n < 0 {
					return fmt.Errorf("WARC record %d has invalid Content-Length %q", recordNumber, value)
				}
				contentLength = n
			case "warc-type":
				warcType = value
			case "warc-record-id":
				if len(value) < 3 || value[0] != '<' || value[len(value)-1] != '>' || !strings.Contains(value, ":") {
					return fmt.Errorf("WARC record %d has invalid WARC-Record-ID %q", recordNumber, value)
				}
			case "warc-date":
				if !strings.HasSuffix(value, "Z") || !strings.Contains(value, "T") {
					return fmt.Errorf("WARC record %d has invalid WARC-Date %q", recordNumber, value)
				}
			}
		}
		for name, present := range required {
			if !present {
				return fmt.Errorf("WARC record %d is missing %s", recordNumber, name)
			}
		}

		blockStart := headerEnd + 4
		blockEnd := blockStart + contentLength
		if blockEnd > len(archive) {
			return fmt.Errorf("WARC record %d block exceeds the archive", recordNumber)
		}
		if blockEnd+4 > len(archive) || !bytes.Equal(archive[blockEnd:blockEnd+4], []byte("\r\n\r\n")) {
			return fmt.Errorf("WARC record %d is missing its trailing CRLF pair", recordNumber)
		}
		if strings.EqualFold(warcType, "response") {
			if err := validateHTTPPayload(archive[blockStart:blockEnd]); err != nil {
				return fmt.Errorf("WARC record %d: %w", recordNumber, err)
			}
		}
		cursor = blockEnd + 4
	}
	return nil
}

func validateHTTPPayload(payload []byte) error {
	headerEnd := bytes.Index(payload, []byte("\r\n\r\n"))
	if headerEnd < 0 {
		return errors.New("HTTP response is missing its header terminator")
	}
	lines := bytes.Split(payload[:headerEnd], []byte("\r\n"))
	if len(lines) == 0 || !bytes.HasPrefix(lines[0], []byte("HTTP/")) {
		return errors.New("HTTP response is missing its status line")
	}
	contentLength := -1
	for _, line := range lines[1:] {
		colon := bytes.IndexByte(line, ':')
		if colon <= 0 {
			return errors.New("HTTP response has an invalid header")
		}
		name := textproto.CanonicalMIMEHeaderKey(strings.TrimSpace(string(line[:colon])))
		if name != "Content-Length" {
			continue
		}
		if contentLength >= 0 {
			return errors.New("HTTP response repeats Content-Length")
		}
		n, err := strconv.Atoi(strings.TrimSpace(string(line[colon+1:])))
		if err != nil || n < 0 {
			return errors.New("HTTP response has invalid Content-Length")
		}
		contentLength = n
	}
	if contentLength < 0 {
		return errors.New("HTTP response is missing Content-Length")
	}
	bodyLength := len(payload) - (headerEnd + 4)
	if contentLength != bodyLength {
		return fmt.Errorf("HTTP Content-Length is %d, body is %d bytes", contentLength, bodyLength)
	}
	return nil
}
