package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/textproto"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

func scaleRouteWARCTransformTimeout(base time.Duration, routeCount int) time.Duration {
	if routeCount <= 1 || base <= 0 {
		return base
	}
	if base > time.Duration(math.MaxInt64/int64(routeCount)) {
		panic("route WARC transform timeout overflow")
	}
	return base * time.Duration(routeCount)
}

func processApplicationWARCArchive(ctx context.Context, pipeline *qinternal.Pipeline, warc []byte, requestID uint64) ([]byte, error) {
	if pipeline == nil {
		return warc, nil
	}
	input := qinternal.NewRawBytesContentWithType(warc, applicationWARCRecipeMIME)
	result, err := pipeline.Process(ctx, input, requestID)
	if err != nil {
		return nil, err
	}
	_, output, err := ensureRawContent(result)
	if err != nil {
		return nil, err
	}
	return output, nil
}

func transformRouteResponseWithApplicationWARC(
	ctx context.Context,
	pipeline *qinternal.Pipeline,
	requestPath string,
	response qinternal.InProcessHTTPResponse,
	requestID uint64,
) (qinternal.InProcessHTTPResponse, error) {
	if pipeline == nil {
		return response, nil
	}
	requestURI := buildWARCRequestURI("qip.local", requestPath)
	record, err := buildMinimalWARCResponseRecord(requestURI, response)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("failed to build WARC record for %q: %w", requestPath, err)
	}
	transformedWARC, err := processApplicationWARCArchive(ctx, pipeline, record, requestID)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, err
	}
	transformedResponse, err := extractWARCResponseRecordByTargetURI(transformedWARC, requestURI)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("failed to parse transformed WARC response for %q: %w", requestPath, err)
	}
	return transformedResponse, nil
}

func buildWARCRequestURI(host string, requestPath string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		host = "qip.local"
	}
	requestPath = strings.TrimSpace(requestPath)
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}
	return "http://" + host + requestPath
}

func buildMinimalWARCResponseRecord(targetURI string, response qinternal.InProcessHTTPResponse) ([]byte, error) {
	targetURI = strings.TrimSpace(targetURI)
	if targetURI == "" {
		return nil, errors.New("target URI must not be empty")
	}

	payload := buildWARCHTTPResponsePayload(response)
	var buf bytes.Buffer
	buf.WriteString("WARC/1.0\r\n")
	buf.WriteString("WARC-Type: response\r\n")
	buf.WriteString("WARC-Target-URI: ")
	buf.WriteString(targetURI)
	buf.WriteString("\r\n")
	buf.WriteString("WARC-Date: ")
	buf.WriteString(time.Now().UTC().Format(time.RFC3339))
	buf.WriteString("\r\n")
	buf.WriteString("WARC-Record-ID: <urn:uuid:qip-dev-response>\r\n")
	buf.WriteString("Content-Type: application/http; msgtype=response\r\n")
	buf.WriteString("Content-Length: ")
	buf.WriteString(strconv.Itoa(len(payload)))
	buf.WriteString("\r\n\r\n")
	buf.Write(payload)
	buf.WriteString("\r\n\r\n")
	return buf.Bytes(), nil
}

func buildWARCHTTPResponsePayload(response qinternal.InProcessHTTPResponse) []byte {
	statusCode := response.StatusCode
	if statusCode == 0 {
		statusCode = http.StatusOK
	}
	statusText := http.StatusText(statusCode)
	if statusText == "" {
		statusText = "Status"
	}

	headers := response.Header.Clone()
	if headers == nil {
		headers = make(http.Header)
	}
	if headers.Get("Content-Length") == "" {
		headers.Set("Content-Length", strconv.Itoa(len(response.Body)))
	}

	keys := make([]string, 0, len(headers))
	for key := range headers {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var payload bytes.Buffer
	fmt.Fprintf(&payload, "HTTP/1.1 %d %s\r\n", statusCode, statusText)
	for _, key := range keys {
		for _, value := range headers[key] {
			payload.WriteString(key)
			payload.WriteString(": ")
			payload.WriteString(value)
			payload.WriteString("\r\n")
		}
	}
	payload.WriteString("\r\n")
	payload.Write(response.Body)
	return payload.Bytes()
}

func extractFirstWARCResponseRecord(warc []byte) (qinternal.InProcessHTTPResponse, error) {
	return extractWARCResponseRecordByTargetURI(warc, "")
}

func extractWARCResponseRecordByTargetURI(warc []byte, targetURI string) (qinternal.InProcessHTTPResponse, error) {
	cursor := 0
	for cursor < len(warc) {
		for cursor < len(warc) && (warc[cursor] == '\r' || warc[cursor] == '\n') {
			cursor++
		}
		if cursor >= len(warc) {
			break
		}

		headerEnd := findHeaderBlockEnd(warc[cursor:])
		if headerEnd == -1 {
			return qinternal.InProcessHTTPResponse{}, errors.New("WARC header terminator not found")
		}
		headerBlock := warc[cursor : cursor+headerEnd]

		warcType := ""
		recordTargetURI := ""
		contentLength := -1
		lines := bytes.Split(headerBlock, []byte("\n"))
		for i, rawLine := range lines {
			line := bytes.TrimSpace(rawLine)
			if len(line) == 0 || i == 0 {
				continue
			}
			colon := bytes.IndexByte(line, ':')
			if colon <= 0 {
				continue
			}
			key := strings.TrimSpace(string(line[:colon]))
			value := strings.TrimSpace(string(line[colon+1:]))
			switch {
			case strings.EqualFold(key, "WARC-Type"):
				warcType = value
			case strings.EqualFold(key, "WARC-Target-URI"):
				recordTargetURI = value
			case strings.EqualFold(key, "Content-Length"):
				n, err := strconv.Atoi(value)
				if err != nil || n < 0 {
					return qinternal.InProcessHTTPResponse{}, fmt.Errorf("invalid WARC Content-Length %q", value)
				}
				contentLength = n
			}
		}
		if contentLength < 0 {
			return qinternal.InProcessHTTPResponse{}, errors.New("WARC record is missing Content-Length")
		}

		payloadStart := cursor + headerEnd
		payloadEnd := payloadStart + contentLength
		if payloadEnd > len(warc) {
			return qinternal.InProcessHTTPResponse{}, errors.New("WARC record payload exceeds archive length")
		}
		payload := warc[payloadStart:payloadEnd]
		if strings.EqualFold(warcType, "response") && (targetURI == "" || recordTargetURI == targetURI) {
			return parseWARCHTTPResponsePayload(payload)
		}
		cursor = payloadEnd
	}
	if targetURI != "" {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("WARC archive has no response record for %s", targetURI)
	}
	return qinternal.InProcessHTTPResponse{}, errors.New("WARC archive has no response record")
}

func parseWARCHTTPResponsePayload(payload []byte) (qinternal.InProcessHTTPResponse, error) {
	headerEnd := findHeaderBlockEnd(payload)
	if headerEnd == -1 {
		return qinternal.InProcessHTTPResponse{}, errors.New("HTTP payload header terminator not found")
	}
	headerBlock := payload[:headerEnd]
	body := slices.Clone(payload[headerEnd:])

	lines := bytes.Split(headerBlock, []byte("\n"))
	if len(lines) == 0 {
		return qinternal.InProcessHTTPResponse{}, errors.New("HTTP payload is missing status line")
	}
	statusLine := strings.TrimSpace(string(lines[0]))
	parts := strings.Fields(statusLine)
	if len(parts) < 2 {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("invalid HTTP status line %q", statusLine)
	}
	statusCode, err := strconv.Atoi(parts[1])
	if err != nil || statusCode < 100 {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("invalid HTTP status code in %q", statusLine)
	}

	headers := make(http.Header)
	for _, rawLine := range lines[1:] {
		line := bytes.TrimSpace(rawLine)
		if len(line) == 0 {
			continue
		}
		colon := bytes.IndexByte(line, ':')
		if colon <= 0 {
			continue
		}
		key := textproto.CanonicalMIMEHeaderKey(strings.TrimSpace(string(line[:colon])))
		if key == "" {
			continue
		}
		value := strings.TrimSpace(string(line[colon+1:]))
		headers.Add(key, value)
	}
	if headers.Get("Content-Length") == "" {
		headers.Set("Content-Length", strconv.Itoa(len(body)))
	}

	return qinternal.InProcessHTTPResponse{
		StatusCode: statusCode,
		Header:     headers,
		Body:       body,
	}, nil
}

func findHeaderBlockEnd(data []byte) int {
	if idx := bytes.Index(data, []byte("\r\n\r\n")); idx >= 0 {
		return idx + 4
	}
	if idx := bytes.Index(data, []byte("\n\n")); idx >= 0 {
		return idx + 2
	}
	return -1
}
