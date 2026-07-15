package main

import (
	"context"
	"sync"

	qinternal "github.com/royalicing/qip/internal"
)

type componentAsset struct {
	body        []byte
	contentType string
}

// RouterFileLayout names the source roots used by QIP Router's file-based
// routing context. Empty optional roots disable that source category.
type RouterFileLayout struct {
	ContentRoot    string
	RecipesRoot    string
	FormsRoot      string
	ComponentsRoot string
	ViewSource     bool
}

// RouterFileState is a complete snapshot of the file-based router inputs.
// It contains discovered source data, but no live WASM runtime resources.
type RouterFileState struct {
	contentRoutes         map[string]qinternal.ContentRoute
	contentRead           contentReadFunc
	routeOptions          qinternal.RouteOptions
	recipeFiles           recipeFileSet
	recipeDigests         map[string][][32]byte
	recipeStamps          map[string]moduleFileStamp
	recipeSourceAssets    []qinternal.RecipeSourceAsset
	recipeSourceByPath    map[string]qinternal.RecipeSourceAsset
	recipeSourceIndex     []byte
	formModules           map[string][]byte
	formDigests           map[string][32]byte
	componentAssets       map[string]componentAsset
	componentRequestPaths []string
}

// RouterServerState is an immutable, ready-to-serve router generation.
// Reloads build a replacement generation before atomically swapping it in.
type RouterServerState struct {
	*RouterFileState
	recipeChains map[string]*qinternal.Pipeline
	recipeOutput map[string]string
}

// routerServerStateSlot keeps a generation alive while requests use it and
// makes replacement a single atomic operation from the router's perspective.
type routerServerStateSlot struct {
	mu    sync.RWMutex
	state *RouterServerState
}

func newRouterServerStateSlot(state *RouterServerState) *routerServerStateSlot {
	return &routerServerStateSlot{state: state}
}

func (slot *routerServerStateSlot) swap(next *RouterServerState) *RouterServerState {
	slot.mu.Lock()
	previous := slot.state
	slot.state = next
	slot.mu.Unlock()
	return previous
}

func (slot *routerServerStateSlot) clear() *RouterServerState {
	return slot.swap(nil)
}

func loadRouterFileState(ctx context.Context, layout RouterFileLayout, routeOptions qinternal.RouteOptions) (*RouterFileState, error) {
	contentRoutes, contentRead, err := loadContentRoutesAndReader(ctx, layout.ContentRoot, routeOptions)
	if err != nil {
		return nil, err
	}
	recipeFiles, recipeDigests, err := loadRecipeFileSet(layout.RecipesRoot)
	if err != nil {
		return nil, err
	}
	recipeStamps, err := scanRecipeModuleStamps(layout.RecipesRoot)
	if err != nil {
		return nil, err
	}
	formModules, formDigests, err := loadFormModules(layout.FormsRoot)
	if err != nil {
		return nil, err
	}
	componentAssets, componentRequestPaths, err := loadComponentAssets(layout.ComponentsRoot)
	if err != nil {
		return nil, err
	}

	recipeSourceAssets := make([]qinternal.RecipeSourceAsset, 0)
	componentSourceAssets := make([]qinternal.RecipeSourceAsset, 0)
	recipeSourceByPath := make(map[string]qinternal.RecipeSourceAsset)
	var recipeSourceIndex []byte
	if layout.ViewSource && layout.RecipesRoot != "" {
		recipeSourceAssets, err = qinternal.CollectRecipeSourceAssets(layout.RecipesRoot)
		if err != nil {
			return nil, err
		}
		componentSourceAssets, err = qinternal.CollectComponentSourceAssets(layout.ComponentsRoot)
		if err != nil {
			return nil, err
		}
		markdownPaths := qinternal.CollectMarkdownRequestPathsFromRoutes(contentRoutes)
		recipeSourceIndex = qinternal.BuildViewSourceIndexHTML(recipeSourceAssets, markdownPaths, componentRequestPaths, componentSourceAssets)
		recipeSourceByPath = make(map[string]qinternal.RecipeSourceAsset, len(recipeSourceAssets)+len(componentSourceAssets))
		for _, asset := range recipeSourceAssets {
			recipeSourceByPath[asset.RequestPath] = asset
		}
		for _, asset := range componentSourceAssets {
			recipeSourceByPath[asset.RequestPath] = asset
		}
	}

	return &RouterFileState{
		contentRoutes:         contentRoutes,
		contentRead:           contentRead,
		routeOptions:          routeOptions,
		recipeFiles:           recipeFiles,
		recipeDigests:         recipeDigests,
		recipeStamps:          recipeStamps,
		recipeSourceAssets:    recipeSourceAssets,
		recipeSourceByPath:    recipeSourceByPath,
		recipeSourceIndex:     recipeSourceIndex,
		formModules:           formModules,
		formDigests:           formDigests,
		componentAssets:       componentAssets,
		componentRequestPaths: componentRequestPaths,
	}, nil
}

func buildRouterServerState(ctx context.Context, files *RouterFileState, opts options) (*RouterServerState, error) {
	recipeChains, err := compileRecipeFileSet(ctx, files.recipeFiles, opts)
	if err != nil {
		return nil, err
	}
	return &RouterServerState{
		RouterFileState: files,
		recipeChains:    recipeChains,
		recipeOutput:    inferRecipeOutputContentTypes(ctx, recipeChains),
	}, nil
}

func loadRouterServerState(ctx context.Context, layout RouterFileLayout, opts options, routeOptions qinternal.RouteOptions) (*RouterServerState, error) {
	files, err := loadRouterFileState(ctx, layout, routeOptions)
	if err != nil {
		return nil, err
	}
	return buildRouterServerState(ctx, files, opts)
}

func (state *RouterServerState) close(ctx context.Context) {
	if state == nil {
		return
	}
	closePipelines(ctx, state.recipeChains)
}
