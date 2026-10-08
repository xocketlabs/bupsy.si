package gate

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Request is a tool call the hook is holding open until something decides.
type Request struct {
	// ID is the name the hook script gave the request, and the name it polls for an answer under.
	ID   string
	Tool string
	// Input is the call's `tool_input`, re-encoded with sorted keys, for display and the audit log.
	Input   string
	Session string
}

// Summary is a one-line rendering for an approval card: the field that actually says what will
// happen. The same keys, in the same order, as the Swift core's GateRequest.summary, so a card
// reads the same wherever the bot runs.
func (r Request) Summary() string {
	var input map[string]any
	if err := json.Unmarshal([]byte(r.Input), &input); err != nil {
		return r.Tool
	}
	for _, key := range []string{"command", "file_path", "path", "url", "pattern", "description"} {
		if value, ok := input[key].(string); ok && value != "" {
			return value
		}
	}
	return r.Tool
}

// Watcher is the other end of the hook script: it reads the requests the script publishes and
// writes the decisions it waits for.
//
// File-based for the same reason the script is. One mechanism serves a local run and a rented
// machine alike, survives either side restarting, and needs nothing but a directory. The Swift
// core's ApprovalGate is the same design; this is its Go counterpart, so a run gated from Go
// behaves like one gated from the Mac.
type Watcher struct {
	dir         string
	seen        map[string]bool
	expiredSeen map[string]bool
}

// NewWatcher watches the gate in dir, creating its subdirectories.
func NewWatcher(dir string) (*Watcher, error) {
	for _, sub := range []string{"pending", "decisions", "expired"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
			return nil, err
		}
	}
	return &Watcher{dir: dir, seen: map[string]bool{}, expiredSeen: map[string]bool{}}, nil
}

// Dir is the gate directory.
func (w *Watcher) Dir() string { return w.dir }

// Poll makes one pass, returning requests and expiries it has not reported before.
//
// Not safe for concurrent use: Watch owns a watcher's polling, and a caller using Poll directly
// does so from one goroutine.
func (w *Watcher) Poll() (requests []Request, expired []string) {
	entries, _ := os.ReadDir(filepath.Join(w.dir, "pending"))
	for _, entry := range entries {
		name := entry.Name()
		// The script writes "<id>.json.part" and renames it, so a .part file is half a request.
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		id := strings.TrimSuffix(name, ".json")
		if w.seen[id] || !validID(id) {
			continue
		}
		w.seen[id] = true
		if request, ok := parseRequest(id, filepath.Join(w.dir, "pending", name)); ok {
			requests = append(requests, request)
		}
	}

	entries, _ = os.ReadDir(filepath.Join(w.dir, "expired"))
	for _, entry := range entries {
		id := entry.Name()
		if strings.HasPrefix(id, ".") || w.expiredSeen[id] {
			continue
		}
		w.expiredSeen[id] = true
		expired = append(expired, id)
	}
	return requests, expired
}

// Watch polls until ctx ends, calling onRequest for each new request and onExpired for each one
// the script gave up on and denied by itself.
//
// Polling rather than a filesystem notifier: a short loop over a directory holding a handful of
// files is cheap, has no platform-specific API behind it, and behaves the same over a network
// filesystem — which is what reading a rented machine's gate will eventually be.
func (w *Watcher) Watch(ctx context.Context, every time.Duration, onRequest func(Request), onExpired func(string)) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		requests, expired := w.Poll()
		for _, request := range requests {
			onRequest(request)
		}
		for _, id := range expired {
			onExpired(id)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Decide answers a waiting call. The script is polling for this file and passes it straight to
// the engine.
//
// Written aside and renamed in, so the script never reads half a decision: an empty or partial
// one is no decision at all, and the script blocks on it rather than guessing.
func (w *Watcher) Decide(id string, allow bool, reason string) error {
	if !validID(id) {
		return fmt.Errorf("not a gate request id: %q", id)
	}
	path := filepath.Join(w.dir, "decisions", id+".json")
	if err := os.WriteFile(path+".part", []byte(HookResponse(allow, reason)), 0o600); err != nil {
		return err
	}
	return os.Rename(path+".part", path)
}

// Expired reports whether the script already gave up on a request and denied it.
//
// Checked directly, not only through Poll, because the script may have given up a moment ago:
// an Allow sent in that gap must not be shown as having taken effect.
func (w *Watcher) Expired(id string) bool {
	if !validID(id) {
		return false
	}
	_, err := os.Stat(filepath.Join(w.dir, "expired", id))
	return err == nil
}

// HookResponse is the exact JSON Claude Code reads back from a PreToolUse hook.
func HookResponse(allow bool, reason string) string {
	decision := "deny"
	if allow {
		decision = "allow"
		if reason == "" {
			reason = "approved in bupsy"
		}
	}
	// A map, so keys come out sorted — the same bytes the Swift core writes.
	payload := map[string]any{
		"hookSpecificOutput": map[string]any{
			"hookEventName":            "PreToolUse",
			"permissionDecision":       decision,
			"permissionDecisionReason": reason,
		},
	}
	data, _ := json.Marshal(payload)
	return string(data)
}

func parseRequest(id, path string) (Request, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Request{}, false
	}
	var body map[string]any
	if err := json.Unmarshal(data, &body); err != nil {
		return Request{}, false
	}
	tool, _ := body["tool_name"].(string)
	if tool == "" {
		return Request{}, false
	}
	input := "{}"
	if raw, ok := body["tool_input"]; ok {
		if encoded, err := json.Marshal(raw); err == nil {
			input = string(encoded)
		}
	}
	session, _ := body["session_id"].(string)
	return Request{ID: id, Tool: tool, Input: input, Session: session}, true
}

// validID accepts the names the script makes ("<pid>-<epoch>-<random>") and nothing that could
// step out of the gate directory.
func validID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for _, r := range id {
		switch {
		case r >= '0' && r <= '9', r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}
