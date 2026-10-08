//go:build !windows

package host

import (
	"os/exec"
	"syscall"
	"time"
)

// configure makes cancelling a run stop everything the engine started, not just the engine.
//
// An engine runs tools as child processes — a shell, a build, the approval hook — and killing only
// the engine would leave those running with nobody reading their output. So the engine starts in
// a process group of its own, and cancelling signals the whole group: SIGTERM first, so the
// engine can finish writing its session, then, after a grace period, the engine itself is killed
// outright by os/exec.
func configure(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		// A negative pid addresses the group whose leader is the engine.
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
	cmd.WaitDelay = 5 * time.Second
}
