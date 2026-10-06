package gate

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// hookCommand reads back the command line the settings file tells Claude Code to run.
func hookCommand(t *testing.T, settingsPath string) string {
	t.Helper()
	raw, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatalf("read settings: %v", err)
	}
	var settings struct {
		Hooks struct {
			PreToolUse []struct {
				Hooks []struct {
					Command string `json:"command"`
				} `json:"hooks"`
			} `json:"PreToolUse"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(raw, &settings); err != nil {
		t.Fatalf("settings are not JSON: %v", err)
	}
	return settings.Hooks.PreToolUse[0].Hooks[0].Command
}

// run executes a command line the way Claude Code does — through a shell — and returns what it
// printed and its exit status.
func run(t *testing.T, commandLine, stdin string) (string, int) {
	t.Helper()
	cmd := exec.Command("/bin/sh", "-c", commandLine)
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.Output()
	var exit *exec.ExitError
	switch {
	case err == nil:
		return string(out), 0
	case errors.As(err, &exit):
		return string(out), exit.ExitCode()
	default:
		t.Fatalf("could not run %q: %v", commandLine, err)
		return "", -1
	}
}

func decision(t *testing.T, out string) string {
	t.Helper()
	var decoded struct {
		HookSpecificOutput struct {
			PermissionDecision string `json:"permissionDecision"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(out), &decoded); err != nil {
		t.Fatalf("gate printed something the engine cannot read: %q", out)
	}
	return decoded.HookSpecificOutput.PermissionDecision
}

// A directory with a space in it is ordinary on a Mac ("Application Support"). Unquoted, the hook
// command would split there, fail to start, and — being a non-blocking error — let the call
// through. Run through a shell exactly as the engine does, it must still reach the script.
func TestHookCommandSurvivesSpacesInThePath(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Application Support", "bupsy gate")
	settings, err := Install(dir, 0)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	out, code := run(t, hookCommand(t, settings), `{"tool_name":"Bash"}`)
	if code != 0 {
		t.Fatalf("hook exited %d; it never reached its own decision", code)
	}
	if got := decision(t, out); got != "deny" {
		t.Errorf("unanswered gate decided %q, want deny", got)
	}
}

// Single quotes cannot be represented inside the script's GATE='...', so they are refused outright
// rather than escaped and hoped about.
func TestInstallRefusesASingleQuote(t *testing.T) {
	if _, err := Install(filepath.Join(t.TempDir(), "it's"), 0); err == nil {
		t.Fatal("installed a gate in a directory whose name breaks the script's quoting")
	}
	script := ShellScript("/tmp/it's", 0)
	if strings.Contains(script, "it's") {
		t.Error("ShellScript embedded a single-quoted directory it cannot quote")
	}
}

func TestShellQuote(t *testing.T) {
	cases := map[string]string{
		"/tmp/bupsy-gate/gate.sh":     "/tmp/bupsy-gate/gate.sh",
		"/Users/a b/gate.sh":          "'/Users/a b/gate.sh'",
		"/tmp/$(touch pwned)/gate.sh": "'/tmp/$(touch pwned)/gate.sh'",
		"/tmp/it's/gate.sh":           `'/tmp/it'\''s/gate.sh'`,
		"":                            "''",
	}
	for in, want := range cases {
		if got := shellQuote(in); got != want {
			t.Errorf("shellQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

// The script's own failures must block. Exit 2 is the only status Claude Code reads as "block";
// anything else is a non-blocking error and the tool call proceeds.
func TestInternalFailureBlocks(t *testing.T) {
	base := t.TempDir()
	// A regular file where the gate directory should be, so mkdir cannot succeed.
	blocker := filepath.Join(base, "not-a-directory")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(base, "gate.sh")
	if err := os.WriteFile(script, []byte(ShellScript(blocker, 0)), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, code := run(t, shellQuote(script), `{"tool_name":"Bash"}`); code != 2 {
		t.Errorf("a gate that could not record the request exited %d, want 2 (block)", code)
	}
}

// answer waits for the request to appear and writes the given decision for it.
func answer(t *testing.T, dir, body string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		entries, _ := os.ReadDir(filepath.Join(dir, "pending"))
		for _, entry := range entries {
			if strings.HasSuffix(entry.Name(), ".json") {
				// Written aside and renamed in, the way the app answers, so the script never sees
				// half a decision.
				path := filepath.Join(dir, "decisions", entry.Name())
				if err := os.WriteFile(path+".part", []byte(body), 0o600); err != nil {
					t.Error(err)
				}
				if err := os.Rename(path+".part", path); err != nil {
					t.Error(err)
				}
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Error("the gate never published a request")
}

func TestDecisionIsPassedOnAndAnEmptyOneBlocks(t *testing.T) {
	allow := `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`
	for _, c := range []struct {
		name, body string
		code       int
		decision   string
	}{
		{"answered", allow, 0, "allow"},
		{"empty", "", 2, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "gate")
			settings, err := Install(dir, 10)
			if err != nil {
				t.Fatalf("install: %v", err)
			}
			done := make(chan struct{})
			go func() { defer close(done); answer(t, dir, c.body) }()
			out, code := run(t, hookCommand(t, settings), `{"tool_name":"Bash"}`)
			<-done
			if code != c.code {
				t.Fatalf("exit %d, want %d", code, c.code)
			}
			if c.decision != "" {
				if got := decision(t, out); got != c.decision {
					t.Errorf("decided %q, want %q", got, c.decision)
				}
			}
		})
	}
}
