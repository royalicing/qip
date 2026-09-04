//go:build windows

package main

import "os"

func tuiTerminationSignals() []os.Signal { return []os.Signal{os.Interrupt} }
func tuiCanSuspend() bool                { return false }
func tuiSuspendSelf() error              { return nil }
