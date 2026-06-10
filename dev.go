package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

func devCmd(args []string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var formsRoot string
	var componentsRoot string
	var modeRaw string
	port := 4000
	fs := flag.NewFlagSet("dev", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var devVerbose bool
	fs.BoolVar(&devVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&devVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&formsRoot, "forms", "", "form QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	fs.BoolVar(&opts.viewSource, "view-source", false, "serve /view-source plus recipe source files from --recipes")
	fs.IntVar(&port, "p", 4000, "port")
	if err := fs.Parse(normalizeDevArgs(args)); err != nil {
		gameOver("%s %v", usageDev, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = devVerbose
	opts.mode = mode
	contentArgs := fs.Args()
	if len(contentArgs) != 1 {
		gameOver(usageDev)
	}
	contentRoot := contentArgs[0]
	if port <= 0 || port > 65535 {
		gameOver("Invalid port: %d", port)
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
	if opts.viewSource && recipesRoot == "" {
		gameOver("--view-source requires --recipes <recipes_dir>")
	}

	routeOptions := qinternal.DefaultRouteOptions()
	state, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, componentsRoot, opts, routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	var stateMu sync.RWMutex
	var reloadMu sync.Mutex
	swapRuntimeState := func(nextState *devRuntimeState) {
		stateMu.Lock()
		previous := state
		state = nextState
		stateMu.Unlock()
		if previous != nil {
			closePipelines(context.Background(), previous.recipeChains)
		}
	}
	reloadRuntimeState := func(reason string) {
		reloadMu.Lock()
		defer reloadMu.Unlock()

		reloadStart := time.Now()
		nextState, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, componentsRoot, opts, routeOptions)
		if err != nil {
			log.Printf("dev: reload failed reason=%s error=%v", reason, err)
			return
		}

		swapRuntimeState(nextState)
		log.Printf("dev: reloaded reason=%s paths=%d recipe_mimes=%d forms=%d components=%d duration_ms=%d", reason, len(nextState.contentRoutes), len(nextState.recipeChains), len(nextState.formModules), len(nextState.componentAssets), time.Since(reloadStart).Milliseconds())
	}
	reloadRecipesIfChanged := func() {
		if opts.mode != modeDev || recipesRoot == "" {
			return
		}

		reloadMu.Lock()
		defer reloadMu.Unlock()

		stamps, err := scanRecipeModuleStamps(recipesRoot)
		if err != nil {
			log.Printf("dev: recipe change check failed: %v", err)
			return
		}

		stateMu.RLock()
		currentStamps := state.recipeStamps
		unchanged := recipeModuleStampsEqual(currentStamps, stamps)
		stateMu.RUnlock()
		if unchanged {
			return
		}

		reloadStart := time.Now()
		nextState, err := loadDevRuntimeState(context.Background(), contentRoot, recipesRoot, formsRoot, componentsRoot, opts, routeOptions)
		if err != nil {
			log.Printf("dev: auto-reload failed reason=recipe_change error=%v", err)
			return
		}

		swapRuntimeState(nextState)
		log.Printf("dev: reloaded reason=recipe_change paths=%d recipe_mimes=%d forms=%d components=%d duration_ms=%d", len(nextState.contentRoutes), len(nextState.recipeChains), len(nextState.formModules), len(nextState.componentAssets), time.Since(reloadStart).Milliseconds())
	}

	defer func() {
		stateMu.Lock()
		current := state
		state = nil
		stateMu.Unlock()
		if current != nil {
			closePipelines(context.Background(), current.recipeChains)
		}
	}()

	log.Printf("dev: indexed %d request paths from %s", len(state.contentRoutes), contentRoot)
	if recipesRoot != "" {
		log.Printf("dev: loaded %d recipe mime chains from %s", len(state.recipeChains), recipesRoot)
	}
	if formsRoot != "" {
		log.Printf("dev: loaded %d form components from %s", len(state.formModules), formsRoot)
	}
	if componentsRoot != "" {
		log.Printf("dev: loaded %d browser components from %s", len(state.componentAssets), componentsRoot)
	}

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	handlerTimeouts := routeHandlerTimeouts{
		contentRecipe:   defaultRouteRecipeTimeout,
		applicationWARC: defaultRouteRecipeTimeout,
	}
	reloadStateIfHardRefresh := func(r *http.Request) {
		if opts.mode != modeDev {
			return
		}
		if !qinternal.IsDevHardRefreshRequest(r) {
			return
		}
		reloadRuntimeState("request_hard_reload")
	}

	handler := newDevRequestHandler("dev", &stateMu, &state, reloadRecipesIfChanged, reloadStateIfHardRefresh, routeOptions, handlerTimeouts)

	server := &http.Server{
		Addr:    addr,
		Handler: handler,
	}

	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	hupCh := make(chan os.Signal, 1)
	signal.Notify(hupCh, syscall.SIGHUP)
	defer signal.Stop(hupCh)

	var reloadWG sync.WaitGroup
	reloadWG.Go(func() {
		for {
			select {
			case <-signalCtx.Done():
				return
			case <-hupCh:
				reloadRuntimeState("signal_hup")
			}
		}
	})
	defer func() {
		stop()
		reloadWG.Wait()
	}()

	go func() {
		<-signalCtx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("dev: listening on http://%s", addr)
	log.Printf("dev: send SIGHUP to reload routes, recipes, forms, and components: `kill -HUP %d`", os.Getpid())
	log.Printf("dev: browser hard reload (Cache-Control: no-cache/max-age=0) triggers full runtime reload")

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		gameOver("dev server error: %v", err)
	}
}
