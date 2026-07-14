package wasmruntime

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/tetratelabs/wazero"
)

// New returns a wazero runtime configured to terminate function execution when call context is canceled or times out.
func New(ctx context.Context) wazero.Runtime {
	runtimeConfig := wazero.NewRuntimeConfig().WithCloseOnContextDone(true)
	return wazero.NewRuntimeWithConfig(ctx, runtimeConfig)
}

// NewRunToCompletion returns a runtime with no cancellation checkpoints:
// module execution always runs to completion, so a non-terminating module
// hangs the caller rather than timing out. `qip comply` uses this because
// compliance is a question of correctness, not speed — a hang is a legible
// verdict — and because WithCloseOnContextDone instrumentation miscompiles
// some modules on the compiler backend (observed on darwin/arm64 with wazero
// v1.11.0 and v1.12.0: a Zig-compiled store loop wrote wrong bytes).
func NewRunToCompletion(ctx context.Context) wazero.Runtime {
	return wazero.NewRuntime(ctx)
}

type executionTimeoutKey struct{}

// WithExecutionTimeout returns a context with timeout and attaches the duration
// so user-facing errors can report the configured module execution limit.
func WithExecutionTimeout(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	return context.WithValue(ctx, executionTimeoutKey{}, timeout), cancel
}

// HumanizeExecutionError rewrites low-level runtime cancellation/timeout errors
// into messages focused on wasm module execution behavior.
func HumanizeExecutionError(ctx context.Context, err error) error {
	if err == nil {
		return nil
	}
	timeoutText := ""
	if timeout, ok := ctx.Value(executionTimeoutKey{}).(time.Duration); ok && timeout > 0 {
		timeoutText = " (" + timeout.String() + ")"
	}
	if errors.Is(err, context.DeadlineExceeded) || strings.Contains(err.Error(), "context deadline exceeded") {
		return errors.New("Wasm module exceeded the execution time limit" + timeoutText + ", please increase --timeout-ms")
	}
	if errors.Is(err, context.Canceled) || strings.Contains(err.Error(), "context canceled") {
		return errors.New("Wasm module execution was canceled")
	}
	return err
}
