// Package fakeengine stands in for the claude and codex binaries in tests.
//
// A test binary calls RunIfRequested from TestMain and then points the runner at itself: started
// with BUPSY_FAKE_ENGINE set, it behaves like the engine instead of running tests. That keeps the
// fake in Go, so it runs the same on every platform the tests do, and it spends nobody's
// subscription.
//
// It is faithful where it matters. It prints the stream shapes recorded from the real binaries
// (the same shapes the conformance cases hold), and for a tool call it runs the PreToolUse hook
// named in --settings exactly as Claude Code does — through sh, with the request on stdin — and
// obeys the decision it prints. So a test through it exercises the real gate script, not a mock.
//
// What it does is chosen by markers in the prompt:
//
//	[tool]   asks to run Bash through the hook, and reports whether it was allowed
//	[sleep]  waits a minute before answering, so a test can stop it
//	[fail]   ends the turn with an error result
//
// Anything else is echoed back. Every invocation's argv is appended to BUPSY_FAKE_LOG, if set.
package fakeengine

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Env is the variable that turns a test binary into the fake.
const Env = "BUPSY_FAKE_ENGINE"

// RunIfRequested runs the fake and exits if this process was started as one.
func RunIfRequested() {
	if os.Getenv(Env) == "" {
		return
	}
	if log := os.Getenv("BUPSY_FAKE_LOG"); log != "" {
		if f, err := os.OpenFile(log, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600); err == nil {
			line, _ := json.Marshal(os.Args[1:])
			f.Write(append(line, '\n'))
			f.Close()
		}
	}
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "exec" {
		os.Exit(codex(args))
	}
	os.Exit(claude(args))
}

func emit(v any) {
	line, _ := json.Marshal(v)
	fmt.Println(string(line))
}

func claude(args []string) int {
	var prompt, resume, settings string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-p":
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "--") {
				prompt = args[i+1]
				i++
			}
		case "--resume":
			resume = args[i+1]
			i++
		case "--settings":
			settings = args[i+1]
			i++
		case "--":
			prompt = strings.Join(args[i+1:], " ")
			i = len(args)
		}
	}
	session := resume
	if session == "" {
		session = "fake-session-1"
	}
	emit(map[string]any{"type": "system", "subtype": "init", "session_id": session})

	if strings.Contains(prompt, "[sleep]") {
		time.Sleep(time.Minute)
	}

	reply := "echo: " + lastLine(prompt)
	if strings.Contains(prompt, "[tool]") {
		input := map[string]any{"command": "echo fake", "description": "print a word"}
		emit(map[string]any{"type": "assistant", "message": map[string]any{"content": []any{
			map[string]any{"type": "tool_use", "id": "call-1", "name": "Bash", "input": input},
		}}})
		allow, reason := askHook(settings, map[string]any{
			"session_id": session, "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": input,
		})
		content, isError := "fake", false
		reply = "I ran it."
		if !allow {
			content, isError = "Permission to use Bash has been denied: "+reason, true
			reply = "I wasn't allowed to run it."
		}
		emit(map[string]any{"type": "user", "message": map[string]any{"content": []any{
			map[string]any{"type": "tool_result", "tool_use_id": "call-1", "content": content, "is_error": isError},
		}}})
	}

	emit(map[string]any{"type": "assistant", "message": map[string]any{"content": []any{
		map[string]any{"type": "text", "text": reply},
	}}})
	if strings.Contains(prompt, "[fail]") {
		emit(map[string]any{"type": "result", "subtype": "error_during_execution", "is_error": true,
			"result": "the fake engine was asked to fail", "session_id": session})
		return 1
	}
	emit(map[string]any{"type": "result", "subtype": "success", "is_error": false, "result": reply,
		"session_id": session, "total_cost_usd": 0.0012,
		"usage": map[string]any{"input_tokens": 3, "output_tokens": 5, "cache_read_input_tokens": 100}})
	return 0
}

// askHook runs the PreToolUse hook from the settings file the way Claude Code does, and reads
// back its decision. No settings, or a hook that blocks (exit 2), is a denial; anything else that
// is not a decision is treated as the real binary would, as a non-blocking error — allowed — so a
// gate that fails open shows up in a test as a call that ran.
func askHook(settingsPath string, request map[string]any) (bool, string) {
	if settingsPath == "" {
		return true, "no hook installed"
	}
	data, err := os.ReadFile(settingsPath)
	if err != nil {
		return true, "settings unreadable"
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
	if json.Unmarshal(data, &settings) != nil || len(settings.Hooks.PreToolUse) == 0 ||
		len(settings.Hooks.PreToolUse[0].Hooks) == 0 {
		return true, "no hook in settings"
	}
	input, _ := json.Marshal(request)
	cmd := exec.Command("/bin/sh", "-c", settings.Hooks.PreToolUse[0].Hooks[0].Command)
	cmd.Stdin = strings.NewReader(string(input))
	out, err := cmd.Output()
	if exit, ok := err.(*exec.ExitError); ok && exit.ExitCode() == 2 {
		return false, "blocked by hook"
	}
	var decision struct {
		Out struct {
			Decision string `json:"permissionDecision"`
			Reason   string `json:"permissionDecisionReason"`
		} `json:"hookSpecificOutput"`
	}
	if json.Unmarshal(out, &decision) != nil {
		return true, "hook said nothing"
	}
	return decision.Out.Decision == "allow", decision.Out.Reason
}

func codex(args []string) int {
	prompt := args[len(args)-1]
	thread := "fake-thread-1"
	for i, arg := range args {
		if arg == "resume" && i+1 < len(args) {
			thread = args[i+1]
		}
	}
	emit(map[string]any{"type": "thread.started", "thread_id": thread})
	emit(map[string]any{"type": "turn.started"})
	emit(map[string]any{"type": "item.completed", "item": map[string]any{
		"id": "item_0", "type": "agent_message", "text": "echo: " + lastLine(prompt)}})
	emit(map[string]any{"type": "turn.completed", "usage": map[string]any{"input_tokens": 3, "output_tokens": 5}})
	return 0
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}
