// Command bupsy-mcp is the MCP server that lets bots work with each other.
//
// It speaks JSON-RPC over stdio, which is what both engines expect of an MCP server. It can drop
// a message for another bot, ask for a new bot to be created, and read who is on the roster. The
// first two only ever drop a request in an outbox directory for bupsy to pick up.
//
// **It does not deliver anything itself, and that is deliberate.** Delivery means writing into
// another bot's conversation, which is the one action that routes around the approval gate — the
// receiving bot would act on an instruction no human read. So this process, which runs inside the
// engine's sandbox and is driven by the model, can only ever *ask*. Whether the message moves is
// decided by bupsy, out of the model's reach, and the first message between any ordered pair stops
// and asks a person.
//
// The outbox is a directory of small JSON files rather than a socket or a database, mirroring the
// approval gate's pending/decisions layout. It needs no dependencies, survives either side
// restarting, and works the same on a rented Linux machine as it does locally.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const protocolVersion = "2024-11-05"

// roster is the path of bupsy's roster file, read by list_bots.
var roster string

// request is one JSON-RPC call. ID is left as raw JSON because the spec permits a string or a
// number and echoing back a different type than was sent breaks strict clients.
type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func main() {
	outbox := os.Getenv("BUPSY_OUTBOX")
	sender := os.Getenv("BUPSY_BOT_ID")
	// Optional: a file bupsy writes listing the roster. Without it list_bots says so plainly.
	roster = os.Getenv("BUPSY_ROSTER")
	if outbox == "" || sender == "" {
		// Refused rather than defaulted. A server that guessed which bot it was speaking for
		// could attribute a message to the wrong one, and attribution is the only thing making
		// an inter-bot message auditable.
		fmt.Fprintln(os.Stderr,
			"bupsy-mcp: BUPSY_OUTBOX and BUPSY_BOT_ID must be set by the host")
		os.Exit(2)
	}

	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	out := json.NewEncoder(os.Stdout)

	for in.Scan() {
		line := strings.TrimSpace(in.Text())
		if line == "" {
			continue
		}

		var req request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			continue
		}
		// A notification has no id and takes no reply. Answering one is a protocol error that
		// some clients treat as fatal.
		if len(req.ID) == 0 {
			continue
		}

		if err := out.Encode(handle(req, outbox, sender)); err != nil {
			return
		}
	}
}

func handle(req request, outbox, sender string) response {
	reply := response{JSONRPC: "2.0", ID: req.ID}

	switch req.Method {
	case "initialize":
		reply.Result = map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "bupsy", "version": "1"},
		}

	case "tools/list":
		reply.Result = map[string]any{"tools": []any{messageBotTool(), createBotTool(), listBotsTool(), askPersonTool(), updateMeTool()}}

	case "tools/call":
		reply.Result = call(req.Params, outbox, sender)

	case "ping":
		reply.Result = map[string]any{}

	default:
		reply.Error = &rpcError{Code: -32601, Message: "unknown method " + req.Method}
	}
	return reply
}

// messageBotTool describes the one tool, including what it cannot promise.
//
// The description tells the model the message may be held for a person, because a tool that
// silently returns success while a human decides teaches the model that the send completed. It
// then reports to the user that it told the other bot something, which may never have happened.
func messageBotTool() map[string]any {
	return map[string]any{
		"name": "message_bot",
		"description": "Send a message to another bupsy bot. The first message to a given bot " +
			"is held until the person approves it, so a successful call means the message was " +
			"queued, not that it was delivered or read. Do not claim the other bot has been " +
			"told until it replies.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"to": map[string]any{
					"type":        "string",
					"description": "The name of the bot to message, as it appears in bupsy.",
				},
				"text": map[string]any{
					"type":        "string",
					"description": "What to say. Written into that bot's conversation, attributed to you.",
				},
			},
			"required": []any{"to", "text"},
		},
	}
}

// createBotTool describes asking for a new bot.
//
// Like message_bot it can only ask: every new bot waits for the person to say yes, because a bot
// that could make bots without anyone noticing could fill the roster, and each new bot runs on the
// person's own subscription.
func createBotTool() map[string]any {
	return map[string]any{
		"name": "create_bot",
		"description": "Ask the person to create a new bupsy bot with its own job — for work " +
			"that deserves a dedicated bot rather than a one-off task. The person must approve " +
			"it, so a successful call means the request is waiting, not that the bot exists. " +
			"Check list_bots first: if a bot already does this, message it instead. Once " +
			"approved, the new bot gets your brief and you can message it with message_bot.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name": map[string]any{
					"type":        "string",
					"description": "A short name for the bot, e.g. \"Researcher\". Must not match an existing bot.",
				},
				"job": map[string]any{
					"type":        "string",
					"description": "What the bot is for, in a sentence or two. Becomes its standing instructions and its first message from you.",
				},
				"role": map[string]any{
					"type":        "string",
					"description": "Optional: a one- or two-word tag shown beside its name, e.g. \"Research\".",
				},
			},
			"required": []any{"name", "job"},
		},
	}
}

// askPersonTool describes asking the person a multiple-choice question.
//
// A question with set answers is quicker to answer than prose and harder to misread: the person
// taps one, or types their own. The answer arrives as their next message, so the bot must stop
// and wait rather than carry on with a guess.
func askPersonTool() map[string]any {
	return map[string]any{
		"name": "ask_person",
		"description": "Ask the person a question with 2 to 4 short answers to choose from (they " +
			"can also type their own). Use it when you need a decision before continuing. " +
			"Their answer arrives as their next message: end your turn right after calling " +
			"this, and do not guess the answer.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"question": map[string]any{
					"type":        "string",
					"description": "The question, in one sentence.",
				},
				"options": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"minItems":    2,
					"maxItems":    4,
					"description": "2 to 4 short answers, a few words each.",
				},
			},
			"required": []any{"question", "options"},
		},
	}
}

// updateMeTool describes a bot setting up its own name, role tag and job.
//
// A new bot starts as "New bot" and learns what it is for in conversation; this is how it then
// becomes that. Name and role are labels and apply at once. The job is the bot's standing
// instructions, so a change to it waits for the person — a bot must not quietly rewrite its own
// orders.
func updateMeTool() map[string]any {
	return map[string]any{
		"name": "update_me",
		"description": "Set your own name, role tag and/or job in bupsy, once the person has " +
			"told you what you are for. Name and role apply immediately; a new job is shown to " +
			"the person to approve first. Only change what they asked for.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name": map[string]any{"type": "string", "description": "A short name for yourself."},
				"role": map[string]any{"type": "string", "description": "A one- or two-word tag, e.g. \"Research\"."},
				"job":  map[string]any{"type": "string", "description": "Your standing instructions, in a sentence or two."},
			},
		},
	}
}

// listBotsTool describes reading the roster.
func listBotsTool() map[string]any {
	return map[string]any{
		"name":        "list_bots",
		"description": "List the other bupsy bots: each one's name and job. Use it before messaging or creating a bot.",
		"inputSchema": map[string]any{"type": "object", "properties": map[string]any{}},
	}
}

type callParams struct {
	Name      string `json:"name"`
	Arguments struct {
		To       string   `json:"to"`
		Text     string   `json:"text"`
		Name     string   `json:"name"`
		Job      string   `json:"job"`
		Role     string   `json:"role"`
		Question string   `json:"question"`
		Options  []string `json:"options"`
	} `json:"arguments"`
}

func call(params json.RawMessage, outbox, sender string) map[string]any {
	var decoded callParams
	if err := json.Unmarshal(params, &decoded); err != nil {
		return toolError("could not read the arguments")
	}
	args := decoded.Arguments

	switch decoded.Name {
	case "message_bot":
		to, text := strings.TrimSpace(args.To), strings.TrimSpace(args.Text)
		if to == "" || text == "" {
			return toolError("both 'to' and 'text' are required")
		}
		if err := drop(outbox, map[string]any{"from": sender, "to": to, "text": text}); err != nil {
			return toolError("could not queue the message: " + err.Error())
		}
		return toolText(fmt.Sprintf(
			"Queued for %s. If this is the first message to them it is waiting on the "+
				"person, so do not assume it has been read.", to))

	case "create_bot":
		name, job := strings.TrimSpace(args.Name), strings.TrimSpace(args.Job)
		if name == "" || job == "" {
			return toolError("both 'name' and 'job' are required")
		}
		if len([]rune(name)) > 40 {
			return toolError("keep the name under 40 characters")
		}
		if err := drop(outbox, map[string]any{
			"kind": "create_bot", "from": sender, "name": name, "job": job,
			"role": strings.TrimSpace(args.Role),
		}); err != nil {
			return toolError("could not queue the request: " + err.Error())
		}
		return toolText(fmt.Sprintf(
			"Asked the person to create %s. It does not exist until they approve — do not say "+
				"it has been created. If they do, %s will message you to say hello.", name, name))

	case "list_bots":
		return listBots()

	case "update_me":
		name, role, job := strings.TrimSpace(args.Name), strings.TrimSpace(args.Role), strings.TrimSpace(args.Job)
		if name == "" && role == "" && job == "" {
			return toolError("give at least one of name, role or job")
		}
		if len([]rune(name)) > 40 {
			return toolError("keep the name under 40 characters")
		}
		if err := drop(outbox, map[string]any{
			"kind": "update_me", "from": sender, "name": name, "role": role, "job": job,
		}); err != nil {
			return toolError("could not update: " + err.Error())
		}
		reply := "Done."
		if job != "" {
			reply = "Name and role (if given) are set. The new job is waiting for the person to approve — do not say it has changed."
		}
		return toolText(reply)

	case "ask_person":
		question := strings.TrimSpace(args.Question)
		var options []string
		for _, option := range args.Options {
			if option = strings.TrimSpace(option); option != "" {
				options = append(options, option)
			}
		}
		if question == "" || len(options) < 2 || len(options) > 4 {
			return toolError("give a question and 2 to 4 non-empty options")
		}
		if err := drop(outbox, map[string]any{
			"kind": "question", "from": sender, "question": question, "options": options,
		}); err != nil {
			return toolError("could not ask: " + err.Error())
		}
		return toolText("Asked the person. Their answer will arrive as their next message — " +
			"end your turn now and do not guess it.")

	default:
		return toolError("unknown tool " + decoded.Name)
	}
}

// listBots reads the roster bupsy wrote. Names and jobs only — the same things the person sees in
// the sidebar, nothing from any bot's conversation.
func listBots() map[string]any {
	if roster == "" {
		return toolError("bupsy did not share the roster with this bot")
	}
	data, err := os.ReadFile(roster)
	if err != nil {
		return toolError("could not read the roster: " + err.Error())
	}
	var bots []struct {
		Name string `json:"name"`
		Job  string `json:"job"`
	}
	if err := json.Unmarshal(data, &bots); err != nil {
		return toolError("the roster file is not readable")
	}
	var lines []string
	for _, bot := range bots {
		if bot.Job == "" {
			lines = append(lines, "- "+bot.Name)
		} else {
			lines = append(lines, "- "+bot.Name+": "+bot.Job)
		}
	}
	if len(lines) == 0 {
		return toolText("No other bots yet.")
	}
	return toolText(strings.Join(lines, "\n"))
}

func toolText(text string) map[string]any {
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}
}

// drop writes the message for bupsy to find.
//
// Written to a temporary name and renamed into place, because the watcher polls this directory and
// must never read a half-written file. Rename within one filesystem is atomic; writing directly
// would hand the reader a truncated message often enough to matter.
func drop(outbox string, fields map[string]any) error {
	if err := os.MkdirAll(outbox, 0o700); err != nil {
		return err
	}

	fields["at"] = time.Now().UTC().Format(time.RFC3339)
	// The run's secret, from the environment the host started the engine with. The host works
	// out who sent a request from this, never from "from": any bot that can write a file could
	// write someone else's id there.
	fields["token"] = os.Getenv("BUPSY_RUN_TOKEN")
	payload, err := json.Marshal(fields)
	if err != nil {
		return err
	}

	name := fmt.Sprintf("%d-%d.json", time.Now().UnixNano(), os.Getpid())
	final := filepath.Join(outbox, name)
	partial := final + ".part"

	if err := os.WriteFile(partial, payload, 0o600); err != nil {
		return err
	}
	return os.Rename(partial, final)
}

// toolError reports a failure to the model rather than to the transport.
//
// MCP distinguishes a tool that failed from a call that could not be made. A protocol-level error
// would read to the engine as the server being broken, and it would stop trying — when what
// actually happened is one bad argument it could fix and retry.
func toolError(message string) map[string]any {
	return map[string]any{
		"isError": true,
		"content": []any{map[string]any{"type": "text", "text": message}},
	}
}
