package gate

import "strings"

// Outcome is what the policy decided about one tool call.
type Outcome struct {
	// Allow is true when the call may run without asking anyone.
	Allow bool
	// Rule says why it was allowed, for the audit log. Empty when it asks.
	Rule string
	// Reason says why a person is being asked, shown on the approval card. Empty when allowed.
	Reason string
}

// Decide says, without asking anyone, whether a tool call needs a human.
//
// A line-for-line port of the Swift core's AutonomyPolicy.decide
// (Packages/BupsyKit/Sources/BupsyKit/Approval/AutonomyPolicy.swift). One bot's trust level must
// mean the same thing whichever core runs it, so the tool lists below are copies, not a fresh
// opinion; change both together. Policy lives here rather than in the hook or the UI so there is
// exactly one place to read when answering "why was this allowed?".
func Decide(tool, autonomy string, allowlist []string) Outcome {
	// bupsy's own tools decide for themselves, out of the model's reach. Exact names, not the
	// mcp__bupsy__ prefix: a connector named "bupsy__x" makes tools called mcp__bupsy__x__…,
	// which a prefix would wave through ungated.
	if bupsyTools[tool] {
		return allowed("bupsy asks about these itself")
	}
	// The engine's own plumbing, not an action: it only loads definitions of tools the bot has.
	if engineInternalTools[tool] {
		return allowed("engine plumbing, touches nothing")
	}

	switch autonomy {
	case "auto":
		return allowed("autonomy: auto")

	case "trusted":
		if readOnlyTools[tool] {
			return allowed("read-only tool")
		}
		if covers(allowlist, tool) {
			return allowed("on this bot's allowlist")
		}
		if isMCP(tool) || outboundTools[tool] {
			return ask("This could reach beyond your computer, so it always asks.")
		}
		if trustedLocalTools[tool] {
			return allowed("autonomy: trusted")
		}
		// Anything not named above asks. An unfamiliar name — a tool an engine adds next
		// release — costs one card; a wrong guess that it was safe costs more.
		return ask("This is not a tool bupsy knows to be safe, so it asks.")

	case "allowlist":
		if covers(allowlist, tool) {
			return allowed("on this bot's allowlist")
		}
		if readOnlyTools[tool] {
			return allowed("read-only tool")
		}
		return ask("Not on the list of things this bot may do without asking.")

	default:
		// "ask", and anything not on the ladder: an unknown trust level is never read as more
		// trust than was granted.
		if covers(allowlist, tool) {
			return allowed("you said always allow")
		}
		return ask("This bot asks before every action.")
	}
}

func allowed(rule string) Outcome { return Outcome{Allow: true, Rule: rule} }
func ask(reason string) Outcome   { return Outcome{Reason: reason} }

// covers reports whether an allowlist covers a tool. An entry ending in "__" is a prefix, so
// allowing "mcp__github__" covers every GitHub tool; anything else is exact, so "Bash" never
// allows "BashOutput".
func covers(allowlist []string, tool string) bool {
	for _, entry := range allowlist {
		if entry == tool || (strings.HasSuffix(entry, "__") && strings.HasPrefix(tool, entry)) {
			return true
		}
	}
	return false
}

func isMCP(tool string) bool { return strings.HasPrefix(tool, "mcp__") }

func set(names ...string) map[string]bool {
	out := make(map[string]bool, len(names))
	for _, name := range names {
		out[name] = true
	}
	return out
}

// Tools that only read. Safe to run unattended once a bot is trusted at all.
var readOnlyTools = set("Read", "Glob", "Grep", "NotebookRead", "TodoWrite", "Task")

// Tools whose effects leave the machine or cannot be undone. Bash is here because its danger
// lives in the argument, not the name: a policy reading tool names cannot tell `ls` from `rm -rf ~`.
var outboundTools = set("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch")

var engineInternalTools = set("ToolSearch")

// A closed list on purpose; see "trusted" in Decide.
var trustedLocalTools = set("LS", "TodoRead", "BashOutput", "ExitPlanMode")

// bupsy's own tools, exactly as cmd/bupsy-mcp serves them under the built-in "bupsy" server.
var bupsyTools = set(
	"mcp__bupsy__message_bot", "mcp__bupsy__create_bot", "mcp__bupsy__list_bots",
	"mcp__bupsy__update_me", "mcp__bupsy__ask_person", "mcp__bupsy__move_bots",
)
