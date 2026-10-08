// Package gate writes the hook script and settings file that make an engine ask before it acts.
package gate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// HookTimeoutSeconds is how long Claude Code is told to wait for the hook.
const HookTimeoutSeconds = 900

// ScriptTimeoutSeconds is how long the script waits before deciding for itself.
//
// Deliberately shorter than the hook timeout, and this is the whole safety argument. A PreToolUse
// hook that times out does NOT block — the call proceeds through the normal permission flow. So a
// gate that simply waited would fail OPEN precisely when nobody was watching, which is the worst
// possible moment. Instead the script answers "deny" with time to spare, and the harness never
// reaches its own timeout.
//
// If you are tempted to raise this, raise HookTimeoutSeconds first and keep the gap.
const ScriptTimeoutSeconds = 870

// Install writes settings.json and gate.sh into dir and returns the settings path to pass to
// `claude --settings`.
func Install(dir string, timeoutSeconds int) (string, error) {
	if timeoutSeconds >= HookTimeoutSeconds {
		// Refused rather than clamped. A gate that quietly becomes fail-open is worse than one
		// that will not install, and a caller passing this has misunderstood the mechanism.
		return "", fmt.Errorf(
			"script timeout %ds must be below the hook timeout %ds, or the gate fails open",
			timeoutSeconds, HookTimeoutSeconds)
	}
	// Absolute, because the hook runs from the engine's working directory, not ours. A relative
	// path would name a script that is not there, and a hook that cannot start does not block.
	dir, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	// The directory is baked into the script inside single quotes, and sh has no way to escape a
	// single quote inside them. Refused rather than escaped: a gate whose script does not parse
	// fails OPEN, because a hook that errors without exiting 2 lets the tool call through.
	if strings.ContainsRune(dir, '\'') {
		return "", fmt.Errorf("gate directory %q contains a single quote, which the hook script cannot hold safely", dir)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}

	script := filepath.Join(dir, "gate.sh")
	// What the shell sees. On Windows the hook runs under Git Bash, which reads "C:/Users/..."
	// as plainly as Windows does, while backslashes would be escapes to it — so the paths baked
	// into the script and the hook command use forward slashes there. Elsewhere this is a no-op.
	shellDir, shellScript := shellPath(dir), shellPath(script)
	if err := os.WriteFile(script, []byte(ShellScript(shellDir, timeoutSeconds)), 0o755); err != nil {
		return "", err
	}

	settings := filepath.Join(dir, "settings.json")
	payload, err := SettingsJSON(shellScript)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(settings, []byte(payload), 0o600); err != nil {
		return "", err
	}
	return settings, nil
}

// shellPath is a native path as sh should be handed it.
func shellPath(path string) string {
	if runtime.GOOS == "windows" {
		return filepath.ToSlash(path)
	}
	return path
}

// SettingsJSON renders the settings file installing the hook.
//
// The hook's "command" is a shell command line, not a path, so the script path is shell-quoted.
// Left bare, a gate directory with a space in it ("Application Support", say) splits into a
// command that does not exist — and a hook that cannot run is a non-blocking error, so every tool
// call would proceed ungated. A path with nothing that needs quoting is left exactly as it is.
func SettingsJSON(scriptPath string) (string, error) {
	// Matches every tool. Narrowing happens in the autonomy policy, not here, so that one place
	// decides what needs a human and the audit log sees every call either way.
	payload := map[string]any{
		"hooks": map[string]any{
			"PreToolUse": []any{map[string]any{
				"matcher": "*",
				"hooks": []any{map[string]any{
					"type":          "command",
					"command":       shellQuote(scriptPath),
					"timeout":       HookTimeoutSeconds,
					"statusMessage": "waiting for your approval in bupsy",
				}},
			}},
		},
	}
	// Indented with two spaces and keys sorted, which Go's encoder does for maps. Both cores
	// generate this byte for byte, and a conformance case holds them to it.
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// shellQuote makes s one word to sh. Words made only of characters sh never treats specially are
// returned unchanged, which keeps an ordinary path byte-for-byte what it was; anything else is
// wrapped in single quotes, with each embedded single quote closed, escaped and reopened.
func shellQuote(s string) string {
	if s != "" && strings.Trim(s, safeShellChars) == "" {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

const safeShellChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"

// ShellScript is the hook body.
//
// Plain sh and coreutils only — it has to run unchanged on a Mac and inside a rented Linux
// machine, and anything it depends on is something that can be missing at 3am. The gate directory
// is baked in at generation time rather than read from the environment, because a hook's
// environment is not ours to rely on.
//
// Every way out other than a decision is exit 2. That is the one status Claude Code treats as
// "block this call"; any other non-zero status is a non-blocking error and the call proceeds. So
// a gate that merely crashed — a full disk, a directory it cannot create, a decision it cannot
// read — would otherwise fail open.
func ShellScript(dir string, timeoutSeconds int) string {
	if strings.ContainsRune(dir, '\'') {
		// Cannot be quoted inside GATE='...'. Install refuses such a directory; this keeps a
		// caller who skipped Install from generating shell that does something else entirely.
		return `#!/bin/sh
echo "bupsy: the approval gate's directory cannot be used safely, so this was blocked" >&2
exit 2
`
	}
	return fmt.Sprintf(`#!/bin/sh
# Generated by bupsy. Holds a tool call open until a human decides.
#
# Fails CLOSED: if nobody answers in time this denies, because a hook that lets its own
# timeout lapse causes the tool call to proceed. And if anything in here fails, it exits 2,
# because 2 is the only status that blocks the call; any other error lets it through.
set -u

fail() {
    echo "bupsy: the approval gate failed ($1), so this was blocked" >&2
    exit 2
}
# Any exit not chosen below — an unset variable, a command that died — becomes a block too.
trap 'status=$?; trap - EXIT; [ "$status" -eq 0 ] || exit 2' EXIT

GATE='%s'
ID="$$-$(date +%%s)-$(awk 'BEGIN{srand();printf "%%d", rand()*100000}')"
PENDING="$GATE/pending/$ID.json"
DECISION="$GATE/decisions/$ID.json"

mkdir -p "$GATE/pending" "$GATE/decisions" "$GATE/expired" || fail "cannot create $GATE"

# Write atomically: the watcher polls this directory and must never read half a file.
cat > "$PENDING.part" || fail "cannot write the request"
mv "$PENDING.part" "$PENDING" || fail "cannot hand the request to bupsy"

i=0
while [ "$i" -lt %d ]; do
    if [ -f "$DECISION" ]; then
        # Read fully before printing: an empty or unreadable decision is no decision at all, and
        # printing nothing would hand the call to the normal permission flow.
        ANSWER=$(cat "$DECISION") || fail "cannot read the decision"
        [ -n "$ANSWER" ] || fail "the decision was empty"
        rm -f "$DECISION" "$PENDING"
        printf '%%s\n' "$ANSWER" || fail "cannot pass the decision on"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

rm -f "$PENDING"
# Tells the app this one was denied for lack of an answer, so its card can settle. Best effort:
# the denial below is what matters, and it must not wait on this.
mkdir -p "$GATE/expired" && : > "$GATE/expired/$ID"
printf '%%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"bupsy: nobody approved this in time, so it was denied"}}' || fail "cannot print the denial"
exit 0
`, dir, timeoutSeconds)
}
