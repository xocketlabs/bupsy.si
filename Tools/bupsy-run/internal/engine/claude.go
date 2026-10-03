package engine

import (
	"fmt"
	"strings"
)

// Claude drives the published `claude` binary in print mode.
//
// We shell out rather than embedding the Agent SDK: Anthropic does not permit third-party
// products to use claude.ai login or subscription rate limits through the SDK, while an end user
// signing into the unmodified binary on a host we provide is expressly allowed. See
// docs/00-compliance-and-auth.md §4. The same rule holds here as in the Swift core — this
// process never reads ~/.claude and never holds a vendor credential.
type Claude struct {
	// Binary lets settings point at a specific build or wrapper. Never hidden from the user.
	Binary string
}

func (c Claude) ID() string { return "claude" }

func (c Claude) binary() string {
	if c.Binary != "" {
		return c.Binary
	}
	return "claude"
}

func (c Claude) Command(req Request) (string, []string) {
	args := []string{"-p", req.Prompt, "--output-format", "stream-json", "--verbose"}
	if req.Resume != "" {
		args = append(args, "--resume", req.Resume)
	}
	if req.Model != "" {
		args = append(args, "--model", req.Model)
	}
	for _, path := range req.MCPConfigs {
		args = append(args, "--mcp-config", path)
	}
	if req.GateSettings != "" {
		// Command-line settings sit above project and user settings in precedence, and — unlike
		// project .claude/settings.json hooks, which do not run in -p sessions — these take
		// effect in print mode, which is the only mode we use.
		args = append(args, "--settings", req.GateSettings)
	}
	// No --permission-mode on purpose: widening permissions is not the same as gating them, and
	// the gate is the hook.
	return c.binary(), args
}

func (c Claude) NormaliseStderr(raw string) []Event {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil
	}
	if looksSignedOut(trimmed) {
		return []Event{{Kind: KindFailed, FailureKind: "notSignedIn", Message: trimmed}}
	}
	return nil
}

// Exit turns a non-zero exit into a failure. Separate from NormaliseStderr because an exit
// status is not a line of output.
func (c Claude) Exit(code int) []Event {
	if code == 0 {
		return nil
	}
	return []Event{{
		Kind:        KindFailed,
		FailureKind: "nonZeroExit",
		Message:     fmt.Sprintf("claude exited %d", code),
	}}
}

func (c Claude) Normalise(raw string) []Event {
	l, ok := parse(raw)
	if !ok {
		return nil
	}

	switch l.str("type") {
	case "system":
		// The init banner carries session id, cwd and the tool list. Only the session id matters
		// to us, and it makes the thread resumable from the very first line.
		if l.str("subtype") != "init" {
			return nil
		}
		var events []Event
		if session := l.str("session_id"); session != "" {
			events = append(events, Event{Kind: KindStarted, ConversationID: session})
		}
		if servers := blocks(l.body["mcp_servers"]); servers != nil {
			states := make([]ConnectorState, 0, len(servers))
			for _, server := range servers {
				name := str(server, "name")
				if name == "" {
					continue
				}
				status := str(server, "status")
				if status == "" {
					status = "unknown"
				}
				states = append(states, ConnectorState{Name: name, Status: status})
			}
			events = append(events, Event{Kind: KindConnectors, Connectors: states})
		}
		return events

	case "rate_limit_event":
		// Undocumented, and valuable: the engine volunteers how much of the user's own
		// subscription window they have burned. Every field is optional because an undocumented
		// shape can change without notice.
		info := l.dict("rate_limit_info")
		if info == nil {
			return []Event{{Kind: KindUnknown, Raw: l.raw}}
		}
		windows := map[string]float64{}
		if unified, ok := info["unifiedWindows"].(map[string]any); ok {
			for name, value := range unified {
				window, ok := value.(map[string]any)
				if !ok {
					continue
				}
				if utilization := floatField(window, "utilization"); utilization != nil {
					windows[name] = *utilization
				}
			}
		}
		return []Event{{
			Kind:    KindRateLimit,
			Status:  str(info, "status"),
			Windows: windows,
		}}

	case "assistant":
		message := l.dict("message")
		if message == nil {
			return []Event{{Kind: KindUnknown, Raw: l.raw}}
		}
		var events []Event
		for _, block := range blocks(message["content"]) {
			switch str(block, "type") {
			case "text":
				if text := str(block, "text"); text != "" {
					events = append(events, Event{Kind: KindText, Text: text})
				}
			case "thinking":
				if text := str(block, "thinking"); text != "" {
					events = append(events, Event{Kind: KindThinking, Text: text})
				}
			case "tool_use":
				name := str(block, "name")
				if name == "" {
					name = "unknown"
				}
				events = append(events, Event{
					Kind:      KindToolCall,
					CallID:    str(block, "id"),
					Name:      name,
					Arguments: encode(block["input"]),
				})
			default:
				events = append(events, Event{Kind: KindUnknown, Raw: l.raw})
			}
		}
		return events

	case "user":
		message := l.dict("message")
		if message == nil {
			return []Event{{Kind: KindUnknown, Raw: l.raw}}
		}
		var events []Event
		for _, block := range blocks(message["content"]) {
			if str(block, "type") != "tool_result" {
				continue
			}
			isError := boolField(block, "is_error")
			events = append(events, Event{
				Kind:    KindToolResult,
				CallID:  str(block, "tool_use_id"),
				Content: flatten(block["content"]),
				IsError: &isError,
			})
		}
		return events

	case "result":
		usage := l.dict("usage")
		event := Event{
			Kind:         KindUsage,
			InputTokens:  intField(usage, "input_tokens"),
			OutputTokens: intField(usage, "output_tokens"),
			CostUSD:      floatField(l.body, "total_cost_usd"),
		}
		isError, hasIsError := l.boolean("is_error")
		if l.str("subtype") != "success" || (hasIsError && isError) {
			message := l.str("result")
			if message == "" {
				message = l.str("subtype")
			}
			if message == "" {
				message = "run failed"
			}
			return []Event{event, {Kind: KindFailed, Message: message}}
		}
		return []Event{event, {
			Kind:           KindDone,
			Text:           l.str("result"),
			ConversationID: l.str("session_id"),
			InputTokens:    event.InputTokens,
			OutputTokens:   event.OutputTokens,
		}}

	default:
		return []Event{{Kind: KindUnknown, Raw: l.raw}}
	}
}

// flatten renders a tool result, which arrives as a string or as content blocks depending on the
// tool.
func flatten(content any) string {
	if text, ok := content.(string); ok {
		return text
	}
	if items := blocks(content); items != nil {
		parts := make([]string, 0, len(items))
		for _, item := range items {
			if text := str(item, "text"); text != "" {
				parts = append(parts, text)
			}
		}
		return strings.Join(parts, "\n")
	}
	if content == nil {
		return ""
	}
	return encode(content)
}

// looksSignedOut is a heuristic, used only to produce a friendlier message — never to make a
// security decision. Kept narrow on purpose so it fails as "unknown" rather than lying.
func looksSignedOut(text string) bool {
	lowered := strings.ToLower(text)
	for _, signal := range []string{
		"not logged in", "please run /login", "authentication", "unauthorized",
		"invalid api key", "no credentials",
	} {
		if strings.Contains(lowered, signal) {
			return true
		}
	}
	return false
}
