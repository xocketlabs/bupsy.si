package host

import (
	"context"
	"fmt"
	"os/exec"
	"sync"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
)

// Run spawns an engine process and calls emit for every canonical event, in order, as they arrive.
//
// It returns when the process has exited and both pipes have been fully drained.
func Run(ctx context.Context, adapter engine.Adapter, req engine.Request) error {
	name, args := adapter.Command(req)
	path, err := Resolve(name)
	if err != nil {
		return err
	}
	return RunResolved(ctx, path, args, adapter, req, func(engine.Event) {})
}

// RunResolved is Run with the binary already located and an emit callback, which is what the
// daemon and the conformance harness both want.
func RunResolved(
	ctx context.Context,
	path string,
	args []string,
	adapter engine.Adapter,
	req engine.Request,
	emit func(engine.Event),
) error {
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Dir = req.WorkingDir

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	// stdin is left nil, which hands the process /dev/null rather than a pipe we never write to.
	// This is load-bearing: with an open stdin, codex prints "Reading additional input from
	// stdin" and then waits forever. A run that hangs instead of finishing is the worst failure
	// mode in this whole program, because nothing reports it.

	if err := cmd.Start(); err != nil {
		return err
	}

	// One mutex rather than a channel: emit is called from both pipe readers, and the ordering
	// that matters (events within a stream) is preserved by each reader being sequential. Two
	// goroutines because draining only one pipe deadlocks as soon as the other fills its buffer —
	// which a long tool result reliably does.
	var mu sync.Mutex
	send := func(events []engine.Event) {
		if len(events) == 0 {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		for _, event := range events {
			emit(event)
		}
	}

	var wait sync.WaitGroup
	wait.Add(2)
	var scanErr error
	go func() {
		defer wait.Done()
		if err := engine.ScanLines(stdout, func(line string) {
			send(adapter.Normalise(line))
		}); err != nil {
			scanErr = err
		}
	}()
	go func() {
		defer wait.Done()
		// stderr scan errors are not reported: stderr is diagnostics, and failing a run because
		// its diagnostics were truncated would turn a cosmetic problem into a lost result.
		_ = engine.ScanLines(stderr, func(line string) {
			send(adapter.NormaliseStderr(line))
		})
	}()
	wait.Wait()

	code := 0
	if err := cmd.Wait(); err != nil {
		var exitErr *exec.ExitError
		if ok := asExitError(err, &exitErr); ok {
			code = exitErr.ExitCode()
		} else {
			return fmt.Errorf("%s: %w", path, err)
		}
	}
	send(adapter.Exit(code))

	return scanErr
}

func asExitError(err error, target **exec.ExitError) bool {
	exitErr, ok := err.(*exec.ExitError)
	if ok {
		*target = exitErr
	}
	return ok
}
