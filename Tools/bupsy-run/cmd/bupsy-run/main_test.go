package main

import "testing"

// The cases that matter are the refusals. A run that starts is one the person believes is held to
// the trust level they gave, so every way of starting one that is not must be an error.
func TestCheckAutonomy(t *testing.T) {
	cases := []struct {
		engine, autonomy string
		ok               bool
		why              string
	}{
		{"codex", "ask", true, "codex enforces ask with a read-only sandbox"},
		{"codex", "allowlist", true, "codex enforces allowlist with a workspace-write sandbox"},
		{"codex", "trusted", true, "codex enforces trusted with a workspace-write sandbox"},
		{"codex", "auto", true, "the top of the ladder"},
		{"claude", "auto", true, "auto asks nobody, so there is nothing to gate"},

		{"claude", "ask", false, "claude below auto needs a person to answer the hook"},
		{"claude", "allowlist", false, "claude below auto needs a person to answer the hook"},
		{"claude", "trusted", false, "trusted still asks about outbound tools"},

		{"codex", "write", false, "an old name from the flag help, never on the ladder"},
		{"claude", "write", false, "an old name from the flag help, never on the ladder"},
		{"codex", "", false, "empty is not a trust level"},
		{"codex", "AUTO", false, "names are exact; case-folding would invent trust"},
	}
	for _, c := range cases {
		err := checkAutonomy(c.engine, c.autonomy)
		if (err == nil) != c.ok {
			t.Errorf("checkAutonomy(%q, %q) = %v, want ok=%v — %s", c.engine, c.autonomy, err, c.ok, c.why)
		}
	}
}
