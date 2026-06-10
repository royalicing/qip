package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"

	qcmd "github.com/royalicing/qip/cmd"
	qinternal "github.com/royalicing/qip/internal"
)

type routeListEntry struct {
	Method      string
	Path        string
	ContentType string
}

func validateRouteAssetRoots(recipesRoot string, formsRoot string, componentsRoot string) error {
	if err := qinternal.ValidateOptionalDirectory("recipes", recipesRoot); err != nil {
		return err
	}
	if err := qinternal.ValidateOptionalDirectory("forms", formsRoot); err != nil {
		return err
	}
	if err := qinternal.ValidateOptionalDirectory("components", componentsRoot); err != nil {
		return err
	}
	return nil
}

func resolveRouteProjectConfig(contentRoot string, recipesRoot string, formsRoot string, componentsRoot string) (qinternal.RouterProjectConfig, error) {
	projectConfig, err := qinternal.ResolveRouterProjectConfig(qinternal.RouterProjectConfig{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		FormsRoot:      formsRoot,
		ComponentsRoot: componentsRoot,
	})
	if err != nil {
		return qinternal.RouterProjectConfig{}, err
	}
	if err := validateRouteAssetRoots(projectConfig.RecipesRoot, projectConfig.FormsRoot, projectConfig.ComponentsRoot); err != nil {
		return qinternal.RouterProjectConfig{}, err
	}
	return projectConfig, nil
}

func routePathCmd(args []string, method string, usage string, logPrefix string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var formsRoot string
	var componentsRoot string
	var modeRaw string

	fs := flag.NewFlagSet("router "+strings.ToLower(method), flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var routeVerbose bool
	fs.BoolVar(&routeVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&routeVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&formsRoot, "forms", "", "form QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	if err := fs.Parse(normalizeRouteArgs(args)); err != nil {
		gameOver("%s %v", usage, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = routeVerbose
	opts.mode = mode

	rest := fs.Args()
	if len(rest) != 2 {
		gameOver("%s", usage)
	}
	contentRoot := rest[0]
	requestPath := rest[1]
	if requestPath == "" {
		requestPath = "/"
	}

	if err := validateContentRootArg(contentRoot); err != nil {
		gameOver("%v", err)
	}
	projectConfig, err := resolveRouteProjectConfig(contentRoot, recipesRoot, formsRoot, componentsRoot)
	if err != nil {
		gameOver("%v", err)
	}
	recipesRoot = projectConfig.RecipesRoot
	formsRoot = projectConfig.FormsRoot
	componentsRoot = projectConfig.ComponentsRoot

	routeOptions := qinternal.DefaultRouteOptions()
	state, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, componentsRoot, opts, routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	var stateMu sync.RWMutex
	defer func() {
		stateMu.Lock()
		current := state
		state = nil
		stateMu.Unlock()
		if current != nil {
			closePipelines(context.Background(), current.recipeChains)
		}
	}()

	handlerTimeouts := routeHandlerTimeouts{
		contentRecipe:   defaultRouteRecipeTimeout,
		applicationWARC: defaultRouteRecipeTimeout,
	}
	handler := newDevRequestHandler(logPrefix, &stateMu, &state, nil, nil, routeOptions, handlerTimeouts)
	response, err := qinternal.ServeInProcessHTTP(handler, method, requestPath, nil)
	if err != nil {
		gameOver("%v", err)
	}

	if contentType := response.Header.Get("Content-Type"); contentType != "" {
		log.Printf("%s: Content-Type: %s", logPrefix, contentType)
	}
	if etag := response.Header.Get("ETag"); etag != "" {
		log.Printf("%s: ETag: %s", logPrefix, etag)
	}
	if location := response.Header.Get("Location"); location != "" {
		log.Printf("%s: Location: %s", logPrefix, location)
	}
	contentLength := response.Header.Get("Content-Length")
	if contentLength == "" {
		contentLength = strconv.Itoa(len(response.Body))
	}
	log.Printf("%s: Content-Length: %s", logPrefix, contentLength)

	if method != http.MethodHead && len(response.Body) > 0 {
		if _, err := os.Stdout.Write(response.Body); err != nil {
			gameOver("Error writing response body: %v", err)
		}
	}

	if response.StatusCode >= http.StatusBadRequest {
		statusText := http.StatusText(response.StatusCode)
		if statusText == "" {
			gameOver("%d", response.StatusCode)
		}
		gameOver("%d %s", response.StatusCode, statusText)
	}
}

func routeListCmd(args []string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var formsRoot string
	var componentsRoot string
	var modeRaw string

	fs := flag.NewFlagSet("router list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var routeVerbose bool
	fs.BoolVar(&routeVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&routeVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&formsRoot, "forms", "", "form QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	if err := fs.Parse(normalizeRouteArgs(args)); err != nil {
		gameOver("%s %v", usageRouteList, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = routeVerbose
	opts.mode = mode

	rest := fs.Args()
	if len(rest) != 1 {
		gameOver("%s", usageRouteList)
	}
	contentRoot := rest[0]

	if err := validateContentRootArg(contentRoot); err != nil {
		gameOver("%v", err)
	}
	projectConfig, err := resolveRouteProjectConfig(contentRoot, recipesRoot, formsRoot, componentsRoot)
	if err != nil {
		gameOver("%v", err)
	}
	recipesRoot = projectConfig.RecipesRoot
	formsRoot = projectConfig.FormsRoot
	componentsRoot = projectConfig.ComponentsRoot

	routeOptions := qinternal.DefaultRouteOptions()
	state, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, componentsRoot, opts, routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	defer closePipelines(context.Background(), state.recipeChains)

	entries := buildRouteListEntries(state)
	for _, entry := range entries {
		fmt.Printf("%-4s %s  %s\n", entry.Method, entry.Path, entry.ContentType)
	}
}

func buildRouteListEntries(state *devRuntimeState) []routeListEntry {
	if state == nil {
		return nil
	}

	canonicalRoutes := make(map[string]qinternal.ContentRoute, len(state.contentRoutes))
	for requestPath := range state.contentRoutes {
		canonicalPath, _ := qinternal.CanonicalRequestPath(requestPath, state.routeOptions)
		if _, exists := canonicalRoutes[canonicalPath]; exists {
			continue
		}
		route, ok := qinternal.ResolveContentRoute(state.contentRoutes, canonicalPath, state.routeOptions)
		if !ok {
			continue
		}
		canonicalRoutes[canonicalPath] = route
	}

	paths := make([]string, 0, len(canonicalRoutes))
	for requestPath := range canonicalRoutes {
		paths = append(paths, requestPath)
	}
	sort.Strings(paths)

	entries := make([]routeListEntry, 0, len(paths)*2)
	for _, requestPath := range paths {
		route := canonicalRoutes[requestPath]
		hasRecipes := shouldApplyRecipesForRequestPath(requestPath, route, state.recipeChains)
		contentType := devResponseContentType(route.SourceMIME, hasRecipes, qinternal.NewRawBytesContent(nil), nil)
		if hasRecipes {
			if recipeType := state.recipeOutput[route.SourceMIME]; recipeType != "" {
				contentType = recipeType
			}
		}
		contentType = mediaTypeOnly(contentType)
		entries = append(entries, routeListEntry{
			Method:      http.MethodGet,
			Path:        requestPath,
			ContentType: contentType,
		})
		entries = append(entries, routeListEntry{
			Method:      http.MethodHead,
			Path:        requestPath,
			ContentType: contentType,
		})
	}
	for _, requestPath := range state.componentRequestPaths {
		asset, ok := state.componentAssets[requestPath]
		if !ok {
			continue
		}
		contentType := mediaTypeOnly(asset.contentType)
		entries = append(entries, routeListEntry{
			Method:      http.MethodGet,
			Path:        requestPath,
			ContentType: contentType,
		})
		entries = append(entries, routeListEntry{
			Method:      http.MethodHead,
			Path:        requestPath,
			ContentType: contentType,
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Path != entries[j].Path {
			return entries[i].Path < entries[j].Path
		}
		return entries[i].Method < entries[j].Method
	})
	return entries
}

func mediaTypeOnly(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "application/octet-stream"
	}
	mediaType, _, err := mime.ParseMediaType(value)
	if err == nil && mediaType != "" {
		return mediaType
	}
	if cut := strings.IndexByte(value, ';'); cut != -1 {
		value = strings.TrimSpace(value[:cut])
	}
	if value == "" {
		return "application/octet-stream"
	}
	return value
}

func firstURIListTarget(body []byte) (string, bool) {
	seenFirstLine := false
	for _, rawLine := range bytes.Split(body, []byte{'\n'}) {
		line := strings.TrimSpace(strings.TrimSuffix(string(rawLine), "\r"))
		if !seenFirstLine {
			seenFirstLine = true
			line = strings.TrimPrefix(line, "\uFEFF")
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		return line, true
	}
	return "", false
}

func routerCmd(args []string) {
	if len(args) == 0 {
		gameOver(usageRoute)
	}
	switch args[0] {
	case "get":
		routePathCmd(args[1:], http.MethodGet, usageRouteGet, "router get")
		return
	case "head":
		routePathCmd(args[1:], http.MethodHead, usageRouteHead, "router head")
		return
	case "list":
		routeListCmd(args[1:])
		return
	case "warc":
	default:
		gameOver(usageRoute)
	}

	type routeRuntime struct {
		state        *devRuntimeState
		routeOptions qinternal.RouteOptions
	}
	handlerTimeouts := routeHandlerTimeouts{
		contentRecipe:   defaultRouteRecipeTimeout,
		applicationWARC: defaultRouteRecipeTimeout,
	}
	warcTransformTimeout := defaultRouteWARCTransformTimeout
	var runtimeMu sync.Mutex
	var runtime *routeRuntime
	ensureRuntime := func(ctx context.Context, request qcmd.RouteWARCRequest) (*routeRuntime, error) {
		runtimeMu.Lock()
		defer runtimeMu.Unlock()
		if runtime != nil {
			return runtime, nil
		}

		mode, err := parseRuntimeMode(request.ModeRaw)
		if err != nil {
			return nil, err
		}
		opts := options{
			verbose:             request.Verbose,
			mode:                mode,
			contentTypeChecking: ContentTypeCheckingStrong,
		}

		if err := validateContentRootArg(request.ContentRoot); err != nil {
			return nil, err
		}
		projectConfig, err := resolveRouteProjectConfig(request.ContentRoot, request.RecipesRoot, request.FormsRoot, request.ComponentsRoot)
		if err != nil {
			return nil, err
		}

		routeOptions := qinternal.DefaultRouteOptions()
		state, err := loadDevRuntimeState(ctx, request.ContentRoot, projectConfig.RecipesRoot, projectConfig.FormsRoot, projectConfig.ComponentsRoot, opts, routeOptions)
		if err != nil {
			return nil, err
		}
		runtime = &routeRuntime{
			state:        state,
			routeOptions: routeOptions,
		}
		return runtime, nil
	}
	defer func() {
		runtimeMu.Lock()
		defer runtimeMu.Unlock()
		if runtime == nil || runtime.state == nil {
			return
		}
		closePipelines(context.Background(), runtime.state.recipeChains)
		runtime.state = nil
	}()

	if err := qcmd.RunRoute(args, qcmd.RouteConfig{
		UsageRoute:     usageRoute,
		UsageRouteWarc: usageRouteWarc,
		DefaultMode:    string(modeDev),
		ListWARCPaths: func(ctx context.Context, request qcmd.RouteWARCRequest) ([]string, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return nil, err
			}

			pathSet := make(map[string]struct{}, len(loaded.state.contentRoutes))
			for requestPath := range loaded.state.contentRoutes {
				canonical, _ := qinternal.CanonicalRequestPath(requestPath, loaded.routeOptions)
				pathSet[canonical] = struct{}{}
			}
			for _, requestPath := range loaded.state.componentRequestPaths {
				pathSet[requestPath] = struct{}{}
			}

			paths := make([]string, 0, len(pathSet))
			for requestPath := range pathSet {
				paths = append(paths, requestPath)
			}
			sort.Strings(paths)
			return paths, nil
		},
		ResolveWARC: func(ctx context.Context, request qcmd.RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return qinternal.InProcessHTTPResponse{}, err
			}
			if asset, ok := loaded.state.componentAssets[request.RequestPath]; ok {
				return qinternal.InProcessHTTPResponse{
					StatusCode: http.StatusOK,
					Header:     http.Header{"Content-Type": []string{asset.contentType}},
					Body:       asset.body,
				}, nil
			}
			response, ok, err := resolveDevBaseRouteResponse(ctx, loaded.state, request.RequestPath, 0, handlerTimeouts)
			if err != nil {
				return qinternal.InProcessHTTPResponse{}, err
			}
			if !ok {
				return qinternal.InProcessHTTPResponse{
					StatusCode: http.StatusNotFound,
					Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
					Body:       []byte("404 page not found\n"),
				}, nil
			}
			return response, nil
		},
		TransformWARC: func(ctx context.Context, request qcmd.RouteWARCRequest, warc []byte) ([]byte, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return nil, err
			}
			pipeline := loaded.state.recipeChains[applicationWARCRecipeMIME]
			if pipeline == nil {
				return warc, nil
			}
			execCtx, cancel := withExecutionTimeout(ctx, scaleRouteWARCTransformTimeout(warcTransformTimeout, request.RouteCount))
			defer cancel()
			transformed, err := processApplicationWARCArchive(execCtx, pipeline, warc, 0)
			if err != nil {
				return nil, err
			}
			return transformed, nil
		},
		Verbosef: func(format string, args ...any) {
			log.Printf(format, args...)
		},
	}); err != nil {
		gameOver("%v", err)
	}
}
