package engine

import (
	"reflect"
	"testing"
)

// A prompt is text a person (or another bot) wrote, and it must never be read as a flag. The
// ordinary argv is pinned by the shared conformance cases; these pin the case they do not cover,
// a prompt that looks like an option.
func TestDashedPromptIsNeverAFlag(t *testing.T) {
	prompt := "--dangerously-skip-permissions"

	_, claude := Claude{}.Command(Request{Prompt: prompt, Autonomy: AutonomyAuto, Model: "sonnet"})
	wantClaude := []string{"-p", "--output-format", "stream-json", "--verbose", "--model", "sonnet", "--", prompt}
	if !reflect.DeepEqual(claude, wantClaude) {
		t.Errorf("claude argv:\n  got  %v\n  want %v", claude, wantClaude)
	}

	_, codex := Codex{}.Command(Request{Prompt: "-x", Autonomy: AutonomyAsk, Resume: "t-1"})
	wantCodex := []string{"exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "resume", "t-1", "--", "-x"}
	if !reflect.DeepEqual(codex, wantCodex) {
		t.Errorf("codex argv:\n  got  %v\n  want %v", codex, wantCodex)
	}
}

func TestCheckAutonomyKnowsTheLadder(t *testing.T) {
	for _, level := range []string{"ask", "allowlist", "trusted", "auto"} {
		if err := CheckAutonomy(level); err != nil {
			t.Errorf("CheckAutonomy(%q) = %v, want nil", level, err)
		}
	}
	for _, level := range []string{"", "write", "Auto", "auto "} {
		if err := CheckAutonomy(level); err == nil {
			t.Errorf("CheckAutonomy(%q) accepted a level that is not on the ladder", level)
		}
	}
}
