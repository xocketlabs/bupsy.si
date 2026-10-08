package host

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
)

// The shim npm writes today, verbatim apart from the package path.
const npmShimText = `@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0

IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
  SET PATHEXT=%PATHEXT:;.JS;=;%
)

endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@anthropic-ai\claude-code\cli.js" %*
`

// The older form, which names node.exe and the script on one line.
const oldShimText = `@IF EXIST "%~dp0\node.exe" (
  "%~dp0\node.exe"  "%~dp0\node_modules\@openai\codex\bin\codex.js" %*
) ELSE (
  node  "%~dp0\node_modules\@openai\codex\bin\codex.js" %*
)
`

func TestNpmShimTarget(t *testing.T) {
	for text, want := range map[string]string{
		npmShimText: `node_modules\@anthropic-ai\claude-code\cli.js`,
		oldShimText: `node_modules\@openai\codex\bin\codex.js`,
	} {
		got, ok := npmShimTarget(text)
		if !ok || got != want {
			t.Errorf("npmShimTarget = %q, %v; want %q", got, ok, want)
		}
	}
	if _, ok := npmShimTarget("@echo off\r\nclaude-real.exe %*\r\n"); ok {
		t.Error("read a shim target out of a batch file that is not npm's")
	}
}

// A prompt is text someone wrote. Through a batch file it would be re-read by cmd.exe, so a shim
// is unwrapped to node and its script, and a batch file that cannot be unwrapped never receives
// an argument cmd.exe would act on.
func TestUnshim(t *testing.T) {
	dir := t.TempDir()
	shim := filepath.Join(dir, "claude.cmd")
	if err := os.WriteFile(shim, []byte(npmShimText), 0o600); err != nil {
		t.Fatal(err)
	}
	node := filepath.Join(dir, "node.exe")
	if err := os.WriteFile(node, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	prompt := `say "hi" & del /q C:\ %PATH%`
	path, args, err := unshim(shim, []string{"-p", prompt})
	if err != nil {
		t.Fatal(err)
	}
	wantScript := filepath.Join(dir, "node_modules", "@anthropic-ai", "claude-code", "cli.js")
	if path != node || !reflect.DeepEqual(args, []string{wantScript, "-p", prompt}) {
		t.Errorf("unshim = %q %q", path, args)
	}

	odd := filepath.Join(dir, "wrapper.bat")
	if err := os.WriteFile(odd, []byte("@echo off\r\nreal.exe %*\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := unshim(odd, []string{"-p", prompt}); err == nil {
		t.Error("passed a prompt cmd.exe would act on through a batch file it could not unwrap")
	}
	if _, args, err := unshim(odd, []string{"-p", "plain words"}); err != nil || args[1] != "plain words" {
		t.Errorf("refused a harmless prompt: %v", err)
	}

	exe := filepath.Join(dir, "claude.exe")
	if path, args, _ := unshim(exe, []string{prompt}); path != exe || args[0] != prompt {
		t.Error("changed the command line of a program that is not a batch file")
	}
}

// Cancelling a run must stop what the engine started, not only the engine: a tool left running
// after Stop is still spending the person's machine with nobody reading it.
func TestCancelStopsTheWholeTree(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses sh; the Windows path is taskkill /T")
	}
	marker := filepath.Join(t.TempDir(), "child-survived")
	// The engine starts a child that would write the marker after a pause, then waits on it.
	script := "(sleep 2; touch '" + marker + "') & wait"
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- RunResolved(ctx, "/bin/sh", []string{"-c", script}, nullAdapter{},
			engine.Request{}, func(engine.Event) {})
	}()
	time.Sleep(300 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("a cancelled run did not return")
	}
	time.Sleep(2500 * time.Millisecond)
	if _, err := os.Stat(marker); err == nil {
		t.Error("the engine's child kept running after the run was cancelled")
	}
}

type nullAdapter struct{}

func (nullAdapter) ID() string                                { return "null" }
func (nullAdapter) Command(engine.Request) (string, []string) { return "", nil }
func (nullAdapter) Normalise(string) []engine.Event           { return nil }
func (nullAdapter) NormaliseStderr(string) []engine.Event     { return nil }
func (nullAdapter) Exit(int) []engine.Event                   { return nil }
