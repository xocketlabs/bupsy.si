//go:build windows

package host

import (
	"os/exec"
	"strconv"
	"syscall"
	"time"
)

// createNoWindow keeps a console program from flashing a window of its own when it is started
// by a program that has none, which is what a desktop app built without a console is.
const createNoWindow = 0x08000000

// configure makes cancelling a run stop everything the engine started, not just the engine.
//
// Windows has no signals to send a process group. Killing the engine alone (what os/exec does by
// default) would leave the tools it started — a shell, node, the approval hook under Git Bash —
// running with nobody reading them. taskkill /T walks the tree from the engine down and ends all
// of it; it ships with every Windows since XP, so this needs nothing extra installed. If it
// cannot run, the engine itself is still killed.
func configure(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	cmd.Cancel = func() error {
		kill := exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid))
		kill.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
		if err := kill.Run(); err != nil {
			return cmd.Process.Kill()
		}
		return nil
	}
	cmd.WaitDelay = 5 * time.Second
}
