package main

import (
	"context"
	"maps"

	qinternal "github.com/royalicing/qip/internal"
)

// PipelineCompiler is the Router Server boundary for turning captured QIP
// components into an executable pipeline.
type PipelineCompiler interface {
	CompilePipeline(context.Context, []ResolvedComponent) (*qinternal.Pipeline, error)
}

// QIPRuntime owns component resolution and compilation policy. Individual
// compiled pipelines own their underlying WASM runtime resources.
type QIPRuntime struct {
	options options
}

func newQIPRuntime(opts options) *QIPRuntime {
	return &QIPRuntime{options: opts}
}

func (runtime *QIPRuntime) ResolveComponents(invocations []ComponentInvocation) ([]ResolvedComponent, error) {
	components := make([]ResolvedComponent, len(invocations))
	for i, invocation := range invocations {
		body, err := resolveModuleSourceWithUniforms(invocation.Source, runtime.options, invocation.UniformValues)
		if err != nil {
			return nil, err
		}
		components[i] = ResolvedComponent{
			Name:          invocation.Source,
			WASM:          body,
			UniformValues: maps.Clone(invocation.UniformValues),
		}
	}
	return components, nil
}

func (runtime *QIPRuntime) CompileInvocations(ctx context.Context, invocations []ComponentInvocation) (*qinternal.Pipeline, error) {
	components, err := runtime.ResolveComponents(invocations)
	if err != nil {
		return nil, err
	}
	return runtime.CompilePipeline(ctx, components)
}

func (runtime *QIPRuntime) CompilePipeline(ctx context.Context, components []ResolvedComponent) (*qinternal.Pipeline, error) {
	return compileResolvedComponents(ctx, components, runtime.options)
}
