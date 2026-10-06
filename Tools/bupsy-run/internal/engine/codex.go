package engine

import (
	"encoding/json"
	"strings"
)

// Codex drives the published `codex` binary in exec mode.
//
// Codex has no blocking hook, so trust is enforced by the sandbox policy chosen before the run
// starts rather than by asking mid-run. That difference is a property of the engine, not a gap in
// this adapter, and the UI states it plainly instead of implying an approval it cannot deliver.
type Codex struct {
	Binary string
}

func (c Codex) ID() string { return "codex" }

func (c Codex) binary() string {
	if c.Binary != "" {
		return c.Binary
	}
	return "codex"
}

func (c Codex) Command(req Request) (string, []string) {
	args := []string{"exec", "--json"}

	sandbox := sandboxFor(req.Autonomy)
	args = append(args, "--sandbox", sandbox)

	if sandbox == "read-only" {
		// Codex refuses to start outside a git repository unless this is passed, which would
		// otherwise make every bot pointed at an ordinary folder fail before it began. Confirmed
		// against the real binary: "Not inside a trusted directory and --skip-git-repo-check was
		// not specified."
		//
		// Passed only for read-only runs. Codex wants a repo so its edits stay recoverable, and
		// that concern is real the moment writes are possible — so a write-capable run keeps the
		// check and the refusal is surfaced to the user as a decision, rather than overridden
		// quietly on their behalf. See NormaliseStderr.
		args = append(args, "--skip-git-repo-check")
	}

	if req.Autonomy == "auto" {
		// Only at the top of the ladder, and only because the user typed a confirmation.
		args = append(args, "--dangerously-bypass-approvals-and-sandbox")
	}
	if req.Model != "" {
		args = append(args, "-m", req.Model)
	}
	if req.WorkingDir != "" {
		args = append(args, "-C", req.WorkingDir)
	}
	if req.Resume != "" {
		// `exec resume <thread_id>` continues a thread; the prompt follows. Last of all, after
		// every option: `codex exec resume` rejects --sandbox and -C, so options placed after
		// the subcommand failed every resumed run before it began.
		args = append(args, "resume", req.Resume)
	}
	if startsLikeOption(req.Prompt) {
		// The prompt is positional, so one starting with "-" would be read as a flag — and
		// "--dangerously-bypass-approvals-and-sandbox" is a flag. "--" ends option parsing, which
		// codex's parser honours. Only for such prompts, so ordinary ones keep the argv the
		// conformance cases pin and the Swift core generates.
		args = append(args, "--")
	}
	args = append(args, req.Prompt)

	// MCP servers are registered out of band with `codex mcp`, not per invocation, so
	// req.MCPConfigs is deliberately not forwarded here. The connector layer installs them once
	// per host instead.
	return c.binary(), args
}

// sandboxFor maps our autonomy ladder onto the only enforcement Codex offers.
//
// Note that "ask" becomes read-only rather than "pause and ask" — the honest translation, and the
// reason the engine reports a gate mechanism at all. Anything unrecognised also lands on
// read-only: an unknown trust level must never be read as more trust than was granted.
func sandboxFor(autonomy string) string {
	switch autonomy {
	case "auto":
		return "danger-full-access"
	case "allowlist", "trusted":
		return "workspace-write"
	default:
		return "read-only"
	}
}

func (c Codex) NormaliseStderr(raw string) []Event {
	trimmed := strings.TrimSpace(raw)

	// "Reading additional input from stdin..." is NOT a problem and must not be reported as one.
	//
	// M0 recorded it as the signal that a host had left stdin open and the run was about to hang.
	// Checked again against the real binary: codex prints it on every single run, including with
	// stdin on /dev/null, where it reads EOF and continues normally. `codex exec --help` confirms
	// the design — stdin is an additional input channel, appended as a <stdin> block when piped.
	//
	// So the line cannot distinguish a hang from a healthy run, and treating it as a protocol
	// error failed every codex run before it produced a single event. A hang is only detectable
	// by a timeout, which belongs to the host, not here.

	// This one genuinely stops the run, and dropping it left the user with no events and no
	// reason — the worst way for anything to fail.
	if strings.Contains(trimmed, "Not inside a trusted directory") {
		return []Event{{
			Kind:        KindFailed,
			FailureKind: "untrustedDirectory",
			Message: "codex will not run in this folder because it is not a git repository. " +
				"Point the bot at a repository, or set it to read-only.",
		}}
	}
	return nil
}

// Exit returns nothing: a rejected turn already produced a failure from the stream, and a second
// one would show the user the same problem twice.
func (c Codex) Exit(int) []Event { return nil }

func (c Codex) Normalise(raw string) []Event {
	l, ok := parse(raw)
	if !ok {
		return nil
	}

	switch l.str("type") {
	case "thread.started":
		// The resume handle, emitted before any work — so a run stays resumable even if the turn
		// then fails. Deliberately not a done event: that would tell the UI a run finished before
		// it began.
		thread := l.str("thread_id")
		if thread == "" {
			return []Event{{Kind: KindUnknown, Raw: l.raw}}
		}
		return []Event{{Kind: KindStarted, ConversationID: thread}}

	case "turn.started":
		return nil

	case "turn.completed":
		usage := l.dict("usage")
		return []Event{{
			Kind:         KindDone,
			InputTokens:  intField(usage, "input_tokens"),
			OutputTokens: intField(usage, "output_tokens"),
		}}

	case "turn.failed":
		return []Event{{Kind: KindFailed, Message: failureMessage(l, "turn failed")}}

	case "error":
		return []Event{{Kind: KindFailed, Message: failureMessage(l, "error")}}

	case "item.completed", "item.started", "item.updated":
		item := l.dict("item")
		if item == nil {
			return []Event{{Kind: KindUnknown, Raw: l.raw}}
		}
		return itemEvents(item, l.raw)

	default:
		return []Event{{Kind: KindUnknown, Raw: l.raw}}
	}
}

// itemEvents maps one stream item. Types beyond error are inferred and not yet observed against a
// working account, so anything unrecognised becomes KindUnknown rather than being dropped: the
// first real successful run will then show us exactly what is missing.
func itemEvents(item map[string]any, raw string) []Event {
	switch str(item, "type") {
	case "error":
		message := str(item, "message")
		if message == "" {
			message = "error item"
		}
		return []Event{{Kind: KindFailed, Message: message}}

	case "agent_message", "assistant_message":
		text := str(item, "text")
		if text == "" {
			text = str(item, "message")
		}
		if text == "" {
			return []Event{{Kind: KindUnknown, Raw: raw}}
		}
		return []Event{{Kind: KindText, Text: text}}

	case "reasoning":
		text := str(item, "text")
		if text == "" {
			text = str(item, "summary")
		}
		if text == "" {
			return nil
		}
		return []Event{{Kind: KindThinking, Text: text}}

	case "command_execution":
		return []Event{{
			Kind:      KindToolCall,
			CallID:    str(item, "id"),
			Name:      "shell",
			Arguments: encode(map[string]string{"command": str(item, "command")}),
		}}

	case "file_change", "patch_apply":
		payload := item["changes"]
		if payload == nil {
			payload = item
		}
		return []Event{{
			Kind:      KindToolCall,
			CallID:    str(item, "id"),
			Name:      "edit",
			Arguments: encode(payload),
		}}

	default:
		return []Event{{Kind: KindUnknown, Raw: raw}}
	}
}

// failureMessage unwraps one level: Codex nests a JSON API error inside a string field, so the
// readable sentence is a layer down from where the stream puts it.
func failureMessage(l line, fallback string) string {
	raw := l.str("message")
	if raw == "" {
		raw = str(l.dict("error"), "message")
	}
	if raw == "" {
		return fallback
	}
	var nested map[string]any
	if err := json.Unmarshal([]byte(raw), &nested); err != nil {
		return raw
	}
	inner, ok := nested["error"].(map[string]any)
	if !ok {
		return raw
	}
	if message := str(inner, "message"); message != "" {
		return message
	}
	return raw
}
