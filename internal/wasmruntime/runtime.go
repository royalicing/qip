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
		return errors.New("Wasm module exceeded the execution time limit" + timeoutText)
	}
	if errors.Is(err, context.Canceled) || strings.Contains(err.Error(), "context canceled") {
		return errors.New("Wasm module execution was canceled")
	}
	return err
}
