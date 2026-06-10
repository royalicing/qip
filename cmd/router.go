package cmd

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

type RouteWARCRequest struct {
	ContentRoot    string
	RequestPath    string
	RouteCount     int
	RecipesRoot    string
	FormsRoot      string
	ComponentsRoot string
	ModeRaw        string
	Host           string
	Verbose        bool
	ViewSource     bool
}

type RouteConfig struct {
	UsageRoute     string
	UsageRouteWarc string
	DefaultMode    string
	ListWARCPaths  func(context.Context, RouteWARCRequest) ([]string, error)
	ResolveWARC    func(context.Context, RouteWARCRequest) (qinternal.InProcessHTTPResponse, error)
	TransformWARC  func(context.Context, RouteWARCRequest, []byte) ([]byte, error)
	Stdout         io.Writer
	WriteFile      func(string, []byte, os.FileMode) error
	Verbosef       func(format string, args ...any)
}

func RunRoute(args []string, config RouteConfig) error {
	if config.ListWARCPaths == nil {
		return errors.New("route path lister is required")
	}
	if config.ResolveWARC == nil {
		return errors.New("route resolver is required")
	}
	if config.Stdout == nil {
		config.Stdout = os.Stdout
	}
	if config.WriteFile == nil {
		config.WriteFile = os.WriteFile
	}
	if config.DefaultMode == "" {
		config.DefaultMode = "dev"
	}

	if len(args) == 0 {
		return errors.New(config.UsageRoute)
	}
	switch args[0] {
	case "warc":
		return runRouteWARC(args[1:], config)
	default:
		return errors.New(config.UsageRoute)
	}
}

func runRouteWARC(args []string, config RouteConfig) error {
	var recipesRoot string
	var formsRoot string
	var componentsRoot string
	var modeRaw string
	hostRaw := "qip.local"
	outputPath := "-"
	viewSource := false

	fs := flag.NewFlagSet("route warc", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var verbose bool
	fs.BoolVar(&verbose, "v", false, "enable verbose logging")
	fs.BoolVar(&verbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&formsRoot, "forms", "", "form QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", config.DefaultMode, "runtime mode")
	fs.StringVar(&hostRaw, "host", hostRaw, "WARC-Target-URI host")
	fs.StringVar(&outputPath, "o", "-", "output WARC path ('-' for stdout)")
	fs.StringVar(&outputPath, "output", "-", "output WARC path ('-' for stdout)")
	fs.BoolVar(&viewSource, "view-source", false, "include /view-source plus recipe source files from --recipes")
	if err := fs.Parse(normalizeRouteWarcArgs(args)); err != nil {
		return fmt.Errorf("%s %w", config.UsageRouteWarc, err)
	}

	host, err := parseRouteWARCHost(hostRaw)
	if err != nil {
		return err
	}

	rest := fs.Args()
	if len(rest) != 1 {
		return errors.New(config.UsageRouteWarc)
	}

	contentRoot := rest[0]
	projectConfig, err := qinternal.ResolveRouterProjectConfig(qinternal.RouterProjectConfig{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		FormsRoot:      formsRoot,
		ComponentsRoot: componentsRoot,
	})
	if err != nil {
		return err
	}
	recipesRoot = projectConfig.RecipesRoot
	formsRoot = projectConfig.FormsRoot
	componentsRoot = projectConfig.ComponentsRoot
	if viewSource && strings.TrimSpace(recipesRoot) == "" {
		return errors.New("--view-source requires --recipes <recipes_dir>")
	}
	baseRequest := RouteWARCRequest{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		FormsRoot:      formsRoot,
		ComponentsRoot: componentsRoot,
		ModeRaw:        modeRaw,
		Host:           host,
		Verbose:        verbose,
		ViewSource:     viewSource,
	}

	paths, err := config.ListWARCPaths(context.Background(), baseRequest)
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		return errors.New("no route paths found to archive")
	}
	sort.Strings(paths)
	baseRequest.RouteCount = len(paths)

	var warcBytes bytes.Buffer
	for _, requestPath := range paths {
		request := baseRequest
		request.RequestPath = requestPath

		response, err := config.ResolveWARC(context.Background(), request)
		if err != nil {
			return fmt.Errorf("failed to resolve path %q: %w", requestPath, err)
		}

		requestURI := "http://" + host + requestPath
		if !strings.HasPrefix(requestPath, "/") {
			requestURI = "http://" + host + "/" + requestPath
		}
		record, err := buildMinimalWARCResponseRecord(requestURI, response)
		if err != nil {
			return fmt.Errorf("failed to build WARC record for %q: %w", requestPath, err)
		}
		warcBytes.Write(record)
	}

	if viewSource {
		markdownPaths := qinternal.FilterMarkdownRequestPaths(paths)
		modulePaths := filterComponentRequestPaths(paths)
		sourceRecords, err := buildRecipeSourceWARCRecords(host, recipesRoot, componentsRoot, markdownPaths, modulePaths)
		if err != nil {
			return err
		}
		for _, record := range sourceRecords {
			warcBytes.Write(record)
		}
	}

	warcOutput := warcBytes.Bytes()
	if config.TransformWARC != nil {
		transformed, err := config.TransformWARC(context.Background(), baseRequest, warcOutput)
		if err != nil {
			return fmt.Errorf("failed to transform warc archive: %w", err)
		}
		warcOutput = transformed
	}

	if outputPath == "" || outputPath == "-" {
		if _, err := config.Stdout.Write(warcOutput); err != nil {
			return fmt.Errorf("error writing WARC to stdout: %w", err)
		}
	} else {
		if err := config.WriteFile(outputPath, warcOutput, 0o644); err != nil {
			return fmt.Errorf("error writing WARC file: %w", err)
		}
	}

	if verbose && config.Verbosef != nil {
		config.Verbosef("route warc: host=%s paths=%d bytes=%d output=%s", host, len(paths), len(warcOutput), outputPath)
	}
	return nil
}

func parseRouteWARCHost(raw string) (string, error) {
	host := strings.TrimSpace(raw)
	if host == "" {
		return "", errors.New("host must not be empty")
	}
	if strings.Contains(host, "://") || strings.Contains(host, "/") {
		return "", fmt.Errorf("invalid host %q", raw)
	}
	return host, nil
}

func normalizeRouteWarcArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"--recipes":    {},
		"--forms":      {},
		"--components": {},
		"--mode":       {},
		"--host":       {},
		"-o":           {},
		"--output":     {},
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func buildMinimalWARCResponseRecord(targetURI string, response qinternal.InProcessHTTPResponse) ([]byte, error) {
	if targetURI == "" {
		return nil, errors.New("target URI must not be empty")
	}

	recordID, err := newWARCRecordID()
	if err != nil {
		return nil, err
	}
	payload := buildHTTPResponsePayload(response)
	timestamp := time.Now().UTC().Format(time.RFC3339)

	var buf bytes.Buffer
	buf.WriteString("WARC/1.0\r\n")
	buf.WriteString("WARC-Type: response\r\n")
	buf.WriteString("WARC-Target-URI: ")
	buf.WriteString(targetURI)
	buf.WriteString("\r\n")
	buf.WriteString("WARC-Date: ")
	buf.WriteString(timestamp)
	buf.WriteString("\r\n")
	buf.WriteString("WARC-Record-ID: ")
	buf.WriteString(recordID)
	buf.WriteString("\r\n")
	buf.WriteString("Content-Type: application/http; msgtype=response\r\n")
	buf.WriteString("Content-Length: ")
	buf.WriteString(strconv.Itoa(len(payload)))
	buf.WriteString("\r\n\r\n")
	buf.Write(payload)
	buf.WriteString("\r\n\r\n")
	return buf.Bytes(), nil
}

func buildHTTPResponsePayload(response qinternal.InProcessHTTPResponse) []byte {
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

func buildRecipeSourceWARCRecords(host string, recipesRoot string, componentsRoot string, markdownRequestPaths []string, componentRequestPaths []string) ([][]byte, error) {
	recipeAssets, err := qinternal.CollectRecipeSourceAssets(recipesRoot)
	if err != nil {
		return nil, err
	}
	componentSourceAssets, err := qinternal.CollectComponentSourceAssets(componentsRoot)
	if err != nil {
		return nil, err
	}
	indexBody := qinternal.BuildViewSourceIndexHTML(recipeAssets, markdownRequestPaths, componentRequestPaths, componentSourceAssets)
	indexResponse := qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
		Body:       indexBody,
	}
	records := make([][]byte, 0, len(recipeAssets)+len(componentSourceAssets)+1)
	indexRecord, err := buildMinimalWARCResponseRecord("http://"+host+"/view-source", indexResponse)
	if err != nil {
		return nil, fmt.Errorf("failed to build WARC record for %q: %w", "/view-source", err)
	}
	records = append(records, indexRecord)
	for _, asset := range recipeAssets {
		response := qinternal.InProcessHTTPResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{asset.ContentType}},
			Body:       asset.Body,
		}
		record, err := buildMinimalWARCResponseRecord("http://"+host+asset.RequestPath, response)
		if err != nil {
			return nil, fmt.Errorf("failed to build WARC record for %q: %w", asset.RequestPath, err)
		}
		records = append(records, record)
	}
	for _, asset := range componentSourceAssets {
		response := qinternal.InProcessHTTPResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{asset.ContentType}},
			Body:       asset.Body,
		}
		record, err := buildMinimalWARCResponseRecord("http://"+host+asset.RequestPath, response)
		if err != nil {
			return nil, fmt.Errorf("failed to build WARC record for %q: %w", asset.RequestPath, err)
		}
		records = append(records, record)
	}
	return records, nil
}

func filterComponentRequestPaths(paths []string) []string {
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		if strings.HasPrefix(p, "/components/") {
			out = append(out, p)
		}
	}
	return out
}

func newWARCRecordID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("failed to generate WARC record id: %w", err)
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"<urn:uuid:%s-%s-%s-%s-%s>",
		hex.EncodeToString(raw[0:4]),
		hex.EncodeToString(raw[4:6]),
		hex.EncodeToString(raw[6:8]),
		hex.EncodeToString(raw[8:10]),
		hex.EncodeToString(raw[10:16]),
	), nil
}
