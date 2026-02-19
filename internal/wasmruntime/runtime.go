package wasmruntime

import (
	"context"
	"errors"
	"strings"

	"github.com/tetratelabs/wazero"
)

// New returns a wazero runtime configured to terminate function execution when call context is canceled or times out.
func New(ctx context.Context) wazero.Runtime {
	runtimeConfig := wazero.NewRuntimeConfig().WithCloseOnContextDone(true)
	return wazero.NewRuntimeWithConfig(ctx, runtimeConfig)
}

// HumanizeExecutionError rewrites low-level runtime cancellation/timeout errors
// into messages focused on wasm module execution behavior.
func HumanizeExecutionError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.DeadlineExceeded) || strings.Contains(err.Error(), "context deadline exceeded") {
		return errors.New("Wasm module exceeded the execution time limit")
	}
	if errors.Is(err, context.Canceled) || strings.Contains(err.Error(), "context canceled") {
		return errors.New("Wasm module execution was canceled")
	}
	return err
}
