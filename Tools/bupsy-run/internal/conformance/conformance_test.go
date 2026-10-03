// Package conformance runs the shared cases in /conformance against this implementation.
//
// These are the cases every implementation of the bupsy core must pass. The macOS app's Swift
// core passes them too, from the same files. That is the whole arrangement: when the two stop
// agreeing, one of these fails and says which, rather than the two drifting apart for months and
// users finding it as a bot that fires at the wrong hour or reports a goal handled when it was
// not.
//
// A failure here is a different kind of failure from an ordinary test going red. An ordinary test
// says this code is wrong. This says this code no longer matches the shared definition — which
// might mean the definition changed and the case should move, but that has to be a decision
// somebody makes, not a diff nobody reads.
package conformance

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/vanshpatelx/bupsy.si/tools/bupsy-run/internal/cron"
	"github.com/vanshpatelx/bupsy.si/tools/bupsy-run/internal/engine"
	"github.com/vanshpatelx/bupsy.si/tools/bupsy-run/internal/gate"
	"github.com/vanshpatelx/bupsy.si/tools/bupsy-run/internal/objective"
)

// root walks up to the repository root so the cases are read from one place rather than copied
// into each implementation. A copy would drift, which is the exact failure this suite exists to
// catch.
func root(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "conformance", "cases")); err == nil {
			return filepath.Join(dir, "conformance", "cases")
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatal("conformance/cases not found above the working directory")
	return ""
}

type spec struct {
	Kind    string `json:"kind"`
	Options struct {
		Engine string `json:"engine"`
	} `json:"options"`
}

func TestConformance(t *testing.T) {
	cases := root(t)
	entries, err := os.ReadDir(cases)
	if err != nil {
		t.Fatalf("read cases: %v", err)
	}

	ran := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		ran++
		name := entry.Name()
		t.Run(name, func(t *testing.T) {
			dir := filepath.Join(cases, name)
			var s spec
			read(t, filepath.Join(dir, "case.json"), &s)

			var expected []map[string]any
			read(t, filepath.Join(dir, "expected.json"), &expected)

			switch s.Kind {
			case "stream":
				checkStream(t, dir, s.Options.Engine, expected)
			case "objective":
				checkObjective(t, expected)
			case "command":
				checkCommand(t, s.Options.Engine, expected)
			case "stderr":
				checkStderr(t, s.Options.Engine, expected)
			case "gate":
				checkGate(t, expected)
			case "cron":
				checkCron(t, expected)
			default:
				t.Fatalf("unknown case kind %q — a new kind needs a runner in every implementation", s.Kind)
			}
		})
	}

	// A suite that silently runs nothing is worse than one that fails: it reports green forever.
	if ran == 0 {
		t.Fatal("no cases ran")
	}
	// Each kind must be represented, so dropping a case directory cannot quietly reduce coverage.
	if ran < 9 {
		t.Errorf("only %d cases ran; the suite had 9 — a case directory went missing", ran)
	}
}

func checkStream(t *testing.T, dir, engineID string, expected []map[string]any) {
	t.Helper()

	adapter := adapterFor(t, engineID)

	input, err := os.Open(filepath.Join(dir, "input.ndjson"))
	if err != nil {
		t.Fatalf("open input: %v", err)
	}
	defer input.Close()

	var actual []engine.Event
	if err := engine.ScanLines(input, func(line string) {
		if strings.TrimSpace(line) == "" {
			return
		}
		actual = append(actual, adapter.Normalise(line)...)
	}); err != nil {
		t.Fatalf("scan input: %v", err)
	}

	if len(actual) != len(expected) {
		t.Fatalf("event count: got %d, want %d\ngot:  %s\nwant: %s",
			len(actual), len(expected), render(actual), render(expected))
	}
	for i, want := range expected {
		compare(t, fmt.Sprintf("event %d", i), asMap(t, actual[i]), want)
	}
}

// checkCommand pins the argv an engine is actually invoked with.
//
// Worth a case of its own because a wrong flag fails before a single event exists, so none of the
// stream cases can see it. Two implementations drifted here within an hour of the second one being
// written — one passed --model where the other passed -m, and one forwarded MCP config paths to an
// engine that has no such flag.
func checkCommand(t *testing.T, engineID string, expected []map[string]any) {
	t.Helper()
	adapter := adapterFor(t, engineID)

	for i, want := range expected {
		spec, _ := want["request"].(map[string]any)
		req := engine.Request{
			Prompt:       str(spec, "prompt"),
			WorkingDir:   str(spec, "workingDir"),
			Resume:       str(spec, "resume"),
			Model:        str(spec, "model"),
			Autonomy:     str(spec, "autonomy"),
			GateSettings: str(spec, "gateSettings"),
		}
		for _, path := range list(spec, "mcpConfigs") {
			req.MCPConfigs = append(req.MCPConfigs, path)
		}

		_, args := adapter.Command(req)
		wantArgs := list(want, "argv")
		label := fmt.Sprintf("command %d (%s)", i, engineID)
		if !reflect.DeepEqual(args, wantArgs) {
			t.Errorf("%s:\n  got  %v\n  want %v%s", label, args, wantArgs, because(want))
		}
	}
}

// checkStderr pins what stderr lines mean — and, as much, what they do not mean. Three of the four
// lines in the codex case must produce nothing, because the expensive mistake here is a
// diagnostic read as a failure.
func checkStderr(t *testing.T, engineID string, expected []map[string]any) {
	t.Helper()
	adapter := adapterFor(t, engineID)

	for i, want := range expected {
		line, _ := want["line"].(string)
		events := adapter.NormaliseStderr(line)
		wantEvents, _ := want["events"].([]any)
		label := fmt.Sprintf("stderr %d (%q)", i, truncate(line))

		if len(events) != len(wantEvents) {
			t.Errorf("%s: produced %d events, want %d — %s%s",
				label, len(events), len(wantEvents), render(events), because(want))
			continue
		}
		for j, wantEvent := range wantEvents {
			wantMap, _ := wantEvent.(map[string]any)
			compare(t, label, asMap(t, events[j]), wantMap)
		}
	}
}

func adapterFor(t *testing.T, engineID string) engine.Adapter {
	t.Helper()
	switch engineID {
	case "claude":
		return engine.Claude{}
	case "codex":
		return engine.Codex{}
	}
	t.Fatalf("unknown engine %q", engineID)
	return nil
}

func str(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

func list(m map[string]any, key string) []string {
	items, _ := m[key].([]any)
	out := make([]string, 0, len(items))
	for _, item := range items {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// checkGate pins the approval gate's fail-closed behaviour.
//
// The timing is the safety argument, so it is asserted as numbers AND by running the generated
// script: a core could agree on both constants and still generate shell that defaults to allow.
func checkGate(t *testing.T, expected []map[string]any) {
	t.Helper()

	for i, want := range expected {
		label := fmt.Sprintf("gate %d", i)

		if n, ok := number(want["hookTimeoutSeconds"]); ok && int(n) != gate.HookTimeoutSeconds {
			t.Errorf("%s: hook timeout = %d, want %d%s",
				label, gate.HookTimeoutSeconds, int(n), because(want))
		}
		if n, ok := number(want["scriptTimeoutSeconds"]); ok && int(n) != gate.ScriptTimeoutSeconds {
			t.Errorf("%s: script timeout = %d, want %d%s",
				label, gate.ScriptTimeoutSeconds, int(n), because(want))
		}
		if first, ok := want["scriptDecidesFirst"].(bool); ok && first {
			if gate.ScriptTimeoutSeconds >= gate.HookTimeoutSeconds {
				t.Errorf("%s: the gate fails OPEN — script %ds is not below hook %ds%s",
					label, gate.ScriptTimeoutSeconds, gate.HookTimeoutSeconds, because(want))
			}
		}

		if refuses, ok := want["refusesTimeoutAtOrAboveHookTimeout"].(bool); ok && refuses {
			if _, err := gate.Install(t.TempDir(), gate.HookTimeoutSeconds); err == nil {
				t.Errorf("%s: installing with a timeout at the hook timeout was accepted%s",
					label, because(want))
			}
		}

		if decision, ok := want["timeoutDecision"].(string); ok {
			checkTimeoutDecision(t, label, decision, want)
		}

		if wantSettings, ok := want["settings"].(map[string]any); ok {
			scriptPath, _ := want["scriptPath"].(string)
			raw, err := gate.SettingsJSON(scriptPath)
			if err != nil {
				t.Fatalf("%s: settings: %v", label, err)
			}
			var got map[string]any
			if err := json.Unmarshal([]byte(raw), &got); err != nil {
				t.Fatalf("%s: generated settings are not valid JSON: %v", label, err)
			}
			// Structure, not bytes: the two cores format JSON differently and both are read the
			// same way by the engine.
			if !reflect.DeepEqual(got, wantSettings) {
				t.Errorf("%s: settings structure differs\n  got  %s\n  want %s%s",
					label, render(got), render(wantSettings), because(want))
			}
		}
	}
}

// checkTimeoutDecision runs the generated script with a zero-second wait and reads the decision it
// prints. Executing it is the point — matching the text would pass on a script that never runs.
func checkTimeoutDecision(t *testing.T, label, wantDecision string, want map[string]any) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "gate.sh")
	if err := os.WriteFile(path, []byte(gate.ShellScript(dir, 0)), 0o755); err != nil {
		t.Fatalf("%s: write script: %v", label, err)
	}

	cmd := exec.Command("/bin/sh", path)
	cmd.Stdin = strings.NewReader(`{"tool_name":"Bash"}`)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("%s: running the gate script failed: %v", label, err)
	}

	var decoded struct {
		HookSpecificOutput struct {
			PermissionDecision string `json:"permissionDecision"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal(out, &decoded); err != nil {
		t.Fatalf("%s: gate printed something the engine cannot read: %q", label, out)
	}
	if decoded.HookSpecificOutput.PermissionDecision != wantDecision {
		t.Errorf("%s: unanswered gate decided %q, want %q%s",
			label, decoded.HookSpecificOutput.PermissionDecision, wantDecision, because(want))
	}
}

func checkObjective(t *testing.T, expected []map[string]any) {
	t.Helper()
	for i, want := range expected {
		reply, _ := want["reply"].(string)
		outcome, detail := objective.Read(reply)
		got := map[string]any{"reply": reply, "outcome": string(outcome)}
		if detail != "" {
			got["detail"] = detail
		}
		compare(t, fmt.Sprintf("reply %d (%q)", i, truncate(reply)), got, want)
	}
}

func checkCron(t *testing.T, expected []map[string]any) {
	t.Helper()
	for _, want := range expected {
		expression, _ := want["expression"].(string)
		parsed, err := cron.Parse(expression)

		got := map[string]any{"expression": expression, "valid": err == nil}
		if err == nil {
			got["minutes"] = parsed.Minutes
			got["hours"] = parsed.Hours
			got["weekdays"] = parsed.Weekdays
			got["daysOfMonth"] = parsed.DaysOfMonth
			got["months"] = parsed.Months
		}
		compare(t, fmt.Sprintf("cron %q", expression), got, want)
	}
}

// compare checks every field the case names, and ignores the rest.
//
// Cases assert what matters rather than every field, so an implementation can carry extra detail —
// a raw line kept for the audit log, a cost figure one engine reports and the other does not —
// without every case having to enumerate it. The flip side is that a case only guards what it
// names, which is why the cases carry their reasoning in a "why" field.
func compare(t *testing.T, label string, got, want map[string]any) {
	t.Helper()
	for key, wantValue := range want {
		// Prose for the humans reading a failure, not an assertion.
		if key == "why" {
			continue
		}
		gotValue, present := got[key]
		if !present {
			t.Errorf("%s: missing %q (want %v)%s", label, key, wantValue, because(want))
			continue
		}
		if !equal(gotValue, wantValue) {
			t.Errorf("%s: %q = %v, want %v%s", label, key, gotValue, wantValue, because(want))
		}
	}
}

// because surfaces the case's own reasoning in the failure message. Without it a drift failure
// reads as a mysterious mismatch, and the fastest resolution is usually to change the expectation
// — exactly the wrong move when the reasoning says why it was chosen.
func because(want map[string]any) string {
	why, ok := want["why"].(string)
	if !ok || why == "" {
		return ""
	}
	return "\n  why this case exists: " + why
}

// equal compares across the JSON/Go number divide: a case's 1200 decodes as float64, and this
// implementation produces int.
func equal(got, want any) bool {
	if reflect.DeepEqual(got, want) {
		return true
	}
	gotNumbers, gotIsList := numbers(got)
	wantNumbers, wantIsList := numbers(want)
	if gotIsList && wantIsList {
		return reflect.DeepEqual(gotNumbers, wantNumbers)
	}
	gotNumber, gotIsNumber := number(got)
	wantNumber, wantIsNumber := number(want)
	return gotIsNumber && wantIsNumber && gotNumber == wantNumber
}

func number(value any) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		return typed, true
	case int:
		return float64(typed), true
	case *int:
		if typed == nil {
			return 0, false
		}
		return float64(*typed), true
	case *float64:
		if typed == nil {
			return 0, false
		}
		return *typed, true
	}
	return 0, false
}

func numbers(value any) ([]float64, bool) {
	switch typed := value.(type) {
	case []int:
		out := make([]float64, len(typed))
		for i, item := range typed {
			out[i] = float64(item)
		}
		return out, true
	case []any:
		out := make([]float64, 0, len(typed))
		for _, item := range typed {
			n, ok := number(item)
			if !ok {
				return nil, false
			}
			out = append(out, n)
		}
		return out, true
	}
	return nil, false
}

// asMap round-trips an event through its canonical JSON, so the cases are checked against what
// this implementation actually writes to a transcript rather than against its in-memory struct.
func asMap(t *testing.T, event engine.Event) map[string]any {
	t.Helper()
	data, err := json.Marshal(event)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("unmarshal event: %v", err)
	}
	return out
}

func read(t *testing.T, path string, into any) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if err := json.Unmarshal(data, into); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
}

func render(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return fmt.Sprintf("%v", value)
	}
	return string(data)
}

func truncate(text string) string {
	text = strings.ReplaceAll(text, "\n", "\\n")
	if len(text) > 48 {
		return text[:48] + "…"
	}
	return text
}
