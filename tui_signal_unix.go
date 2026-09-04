//go:build !windows

package main

import (
	"os"
	"syscall"
)

func tuiTerminationSignals() []os.Signal {
	return []os.Signal{os.Interrupt, syscall.SIGTERM, syscall.SIGHUP}
}

func tuiCanSuspend() bool { return true }

func tuiSuspendSelf() error {
	return syscall.Kill(os.Getpid(), syscall.SIGTSTP)
}
