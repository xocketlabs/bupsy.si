package gate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"
)

// The watcher and the script must agree on the protocol end to end: the script publishes, the
// watcher reads, the watcher answers, the script passes the answer on. Run for real rather than
// mocked, because a disagreement about a file name fails OPEN.
func TestWatcherAnswersTheScript(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the hook is a sh script; run under Git Bash on Windows")
	}
	for _, allow := range []bool{true, false} {
		dir := filepath.Join(t.TempDir(), "gate dir")
		settings, err := Install(dir, 10)
		if err != nil {
			t.Fatal(err)
		}
		watcher, err := NewWatcher(dir)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		var wg sync.WaitGroup
		wg.Add(1)
		var seen Request
		go func() {
			defer wg.Done()
			watcher.Watch(ctx, 20*time.Millisecond, func(r Request) {
				seen = r
				if err := watcher.Decide(r.ID, allow, "test"); err != nil {
					t.Error(err)
				}
			}, func(string) {})
		}()
		out, code := run(t, hookCommand(t, settings),
			`{"tool_name":"Bash","tool_input":{"command":"ls -la","description":"list"},"session_id":"s1"}`)
		cancel()
		wg.Wait()
		if code != 0 {
			t.Fatalf("hook exited %d", code)
		}
		want := map[bool]string{true: "allow", false: "deny"}[allow]
		if got := decision(t, out); got != want {
			t.Errorf("decided %q, want %q", got, want)
		}
		if seen.Tool != "Bash" || seen.Session != "s1" || seen.Summary() != "ls -la" {
			t.Errorf("request read as %+v (summary %q)", seen, seen.Summary())
		}
	}
}

// A script that waits out its time denies by itself and leaves a marker, so the app can settle
// the card instead of offering an Allow that would do nothing.
func TestExpiryIsReported(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the hook is a sh script; run under Git Bash on Windows")
	}
	dir := t.TempDir()
	settings, err := Install(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	watcher, err := NewWatcher(dir)
	if err != nil {
		t.Fatal(err)
	}
	out, _ := run(t, hookCommand(t, settings), `{"tool_name":"Bash"}`)
	if got := decision(t, out); got != "deny" {
		t.Fatalf("unanswered gate decided %q", got)
	}
	_, expired := watcher.Poll()
	if len(expired) != 1 || !watcher.Expired(expired[0]) {
		t.Fatalf("expired = %v; the script's own denial went unreported", expired)
	}
	if _, again := watcher.Poll(); len(again) != 0 {
		t.Errorf("an expiry was reported twice: %v", again)
	}
}

func TestHookResponseIsWhatClaudeReads(t *testing.T) {
	var decoded struct {
		Out map[string]string `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(HookResponse(false, "you declined it")), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Out["hookEventName"] != "PreToolUse" || decoded.Out["permissionDecision"] != "deny" ||
		decoded.Out["permissionDecisionReason"] != "you declined it" {
		t.Errorf("hook response = %v", decoded.Out)
	}
}

// Ids come from file names the script chose, but Decide also takes them from callers; a name
// that steps out of the gate directory must never become a path.
func TestDecideRefusesPathsAsIDs(t *testing.T) {
	watcher, err := NewWatcher(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"../x", "a/b", `a\b`, "", ".."} {
		if err := watcher.Decide(id, true, ""); err == nil {
			t.Errorf("Decide(%q) wrote a decision", id)
		}
	}
	// A half-written request is not read.
	pending := filepath.Join(watcher.Dir(), "pending", "1-2-3.json.part")
	if err := os.WriteFile(pending, []byte(`{"tool_name":"Bash"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if requests, _ := watcher.Poll(); len(requests) != 0 {
		t.Errorf("read a .part file as a request: %v", requests)
	}
}

// The ladder, pinned to what the Swift policy does. A trust level must mean the same on every
// core, so a change here is a change to make on both.
func TestPolicyMatchesTheSwiftCore(t *testing.T) {
	cases := []struct {
		tool, autonomy string
		allowlist      []string
		allow          bool
	}{
		{"Bash", "ask", nil, false},
		{"Read", "ask", nil, false},
		{"Bash", "ask", []string{"Bash"}, true},
		{"mcp__bupsy__message_bot", "ask", nil, true},
		{"mcp__bupsy__x__steal", "auto", nil, true}, // auto allows everything anyway
		{"mcp__bupsy__x__steal", "trusted", nil, false},
		{"ToolSearch", "ask", nil, true},
		{"Read", "allowlist", nil, true},
		{"Bash", "allowlist", nil, false},
		{"mcp__github__create_issue", "allowlist", []string{"mcp__github__"}, true},
		{"BashOutput", "allowlist", []string{"Bash"}, false},
		{"Read", "trusted", nil, true},
		{"LS", "trusted", nil, true},
		{"Bash", "trusted", nil, false},
		{"WebFetch", "trusted", nil, false},
		{"PowerShell", "trusted", nil, false},
		{"Bash", "trusted", []string{"Bash"}, true},
		{"Bash", "auto", nil, true},
		{"Read", "write", nil, false}, // not on the ladder: the most restrictive reading
	}
	for _, c := range cases {
		got := Decide(c.tool, c.autonomy, c.allowlist)
		if got.Allow != c.allow {
			t.Errorf("Decide(%q, %q, %v) allow=%v, want %v", c.tool, c.autonomy, c.allowlist, got.Allow, c.allow)
		}
		if got.Allow && got.Rule == "" || !got.Allow && got.Reason == "" {
			t.Errorf("Decide(%q, %q) gave no rule or reason: %+v", c.tool, c.autonomy, got)
		}
	}
}
