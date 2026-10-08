// Command bupsy-mcp is the MCP server that lets bots work with each other.
//
// It speaks JSON-RPC over stdio, which is what both engines expect of an MCP server. It can drop
// a message for another bot, ask for a new bot to be created, file bots into sidebar sections,
// and read who is on the roster. The
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

// self is the asking bot's id, left out of its own list_bots.
var self string

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
	self = sender
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
		reply.Result = map[string]any{"tools": []any{messageBotTool(), createBotTool(), listBotsTool(), askPersonTool(), updateMeTool(), moveBotsTool(), manageBotTool(),
			addRoutineTool(), removeRoutineTool(), stopBotTool(), readChatTool(), notifyPersonTool()}}

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

// moveBotsTool describes filing bots into a sidebar section.
//
// Sections are labels the person sees in the sidebar, nothing more: moving a bot changes no job,
// no trust and no conversation, and the person can drag it back. So it applies at once, like a
// bot's own name, and bupsy notes what moved in the asking bot's chat.
func moveBotsTool() map[string]any {
	return map[string]any{
		"name": "move_bots",
		"description": "Move bupsy bots into a section of the sidebar, making the section if it " +
			"does not exist yet. Use it when the person asks you to organise or group bots. " +
			"Use names exactly as list_bots shows them; you can include yourself. An empty " +
			"section moves the bots out of any section.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"bots": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"minItems":    1,
					"description": "The names of the bots to move.",
				},
				"section": map[string]any{
					"type":        "string",
					"description": "The section to put them in, e.g. \"Frontier & Co\". Empty for no section.",
				},
			},
			"required": []any{"bots", "section"},
		},
	}
}

// manageBotTool describes changing another bot: its job, role tag and model, and starting it on a
// fresh conversation with a first message there.
//
// Unlike update_me and move_bots it is not one of the tools bupsy waves through: changing what
// another bot does goes through the approval gate like any connector tool, so a bot the person
// set to ask first asks, and only a bot on "auto" applies it at once. Every change is noted in
// both chats, so the person sees who changed what.
func manageBotTool() map[string]any {
	return map[string]any{
		"name": "manage_bot",
		"description": "Change a bupsy bot: its job (standing instructions), role tag or model, " +
			"and/or start it on a fresh chat. A fresh chat forgets the old conversation's " +
			"context (its history stays on screen), which saves usage once a chat has grown " +
			"long; give 'message' to tell it where to pick up. Use names exactly as list_bots " +
			"shows them; you can name yourself to start your own fresh chat with a hand-off " +
			"note. A bot that is working gets the fresh chat when it finishes. Only change " +
			"what the person asked for.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"bot":  map[string]any{"type": "string", "description": "The bot's name, as list_bots shows it."},
				"job":  map[string]any{"type": "string", "description": "Its new standing instructions. Replaces the old job entirely."},
				"role": map[string]any{"type": "string", "description": "A one- or two-word tag, e.g. \"Research\"."},
				"model": map[string]any{
					"type":        "string",
					"description": "The model, as list_bots shows the choices, e.g. \"sonnet\" or \"opus\". \"default\" for whatever its CLI is set to.",
				},
				"engine": map[string]any{
					"type":        "string",
					"description": "\"claude\" or \"codex\". Switching engines also switches to that engine's own conversation, and resets the model to its default.",
				},
				"fresh_chat": map[string]any{"type": "boolean", "description": "Start a new conversation, leaving the old context behind."},
				"message": map[string]any{
					"type":        "string",
					"description": "Sent to the bot after the other changes, as the first message of its fresh chat if you asked for one.",
				},
			},
			"required": []any{"bot"},
		},
	}
}

// addRoutineTool describes scheduling a message to a bot.
//
// A routine is the same thing the person sets up under a bot's Routines: on a schedule, bupsy
// sends the bot a message and it works on it. Gated by the asking bot's trust like manage_bot,
// since a routine spends the person's usage on a timer.
func addRoutineTool() map[string]any {
	return map[string]any{
		"name": "add_routine",
		"description": "Schedule a message that bupsy sends to a bot on a schedule, e.g. a daily " +
			"\"start the day\" at 2pm. The bot works on it as if the person had sent it. You can " +
			"schedule yourself. The schedule is five-field cron in this Mac's local time: minute " +
			"hour day-of-month month day-of-week, e.g. \"0 14 * * *\" (every day at 2pm) or " +
			"\"30 9 * * 1-5\" (weekdays at 9:30). Lists and ranges work; step syntax (*/n) does " +
			"not. A routine with the same name on that bot is replaced. list_bots shows routines.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"bot":      map[string]any{"type": "string", "description": "The bot to message, as list_bots shows it."},
				"name":     map[string]any{"type": "string", "description": "A short name, e.g. \"Start the day\"."},
				"message":  map[string]any{"type": "string", "description": "What bupsy sends the bot each time."},
				"schedule": map[string]any{"type": "string", "description": "Five-field cron, local time."},
				"when_closed": map[string]any{
					"type":        "boolean",
					"description": "Also run while the Bupsy app is closed (it opens to run it). Default: only while Bupsy is open.",
				},
			},
			"required": []any{"bot", "name", "message", "schedule"},
		},
	}
}

func removeRoutineTool() map[string]any {
	return map[string]any{
		"name":        "remove_routine",
		"description": "Delete a bot's routine by name, as list_bots shows it.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"bot":  map[string]any{"type": "string", "description": "The bot whose routine it is."},
				"name": map[string]any{"type": "string", "description": "The routine's name."},
			},
			"required": []any{"bot", "name"},
		},
	}
}

func stopBotTool() map[string]any {
	return map[string]any{
		"name": "stop_bot",
		"description": "Stop a bot that is working, as the person's Stop button does. What it " +
			"has done so far stays; anything queued for it waits. Use it for a bot stuck in a " +
			"loop or doing the wrong thing, not to end your own turn.",
		"inputSchema": map[string]any{
			"type":       "object",
			"properties": map[string]any{"bot": map[string]any{"type": "string", "description": "The bot to stop."}},
			"required":   []any{"bot"},
		},
	}
}

func readChatTool() map[string]any {
	return map[string]any{
		"name": "read_chat",
		"description": "Read the latest messages in another bot's chat with the person: what " +
			"was asked, and what it replied. Saved when each of its turns ends, so a bot that " +
			"is working shows up to its last finished turn. Tool calls are left out.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"bot":  map[string]any{"type": "string", "description": "The bot, as list_bots shows it."},
				"last": map[string]any{"type": "integer", "description": "How many messages, newest last. Default 10, at most 40."},
			},
			"required": []any{"bot"},
		},
	}
}

func notifyPersonTool() map[string]any {
	return map[string]any{
		"name": "notify_person",
		"description": "Send the person a notification on their Mac, for something they should " +
			"know soon (a batch finished, something broke). Not for questions: use ask_person. " +
			"Use sparingly.",
		"inputSchema": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"title": map[string]any{"type": "string", "description": "Optional short title. Defaults to your name."},
				"text":  map[string]any{"type": "string", "description": "One or two sentences."},
			},
			"required": []any{"text"},
		},
	}
}

// listBotsTool describes reading the roster.
func listBotsTool() map[string]any {
	return map[string]any{
		"name":        "list_bots",
		"description": "List the other bupsy bots: each one's name, sidebar section, model, whether it is working, its job and its routines. Use it before messaging, creating, moving, managing or scheduling a bot.",
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
		Bots     []string `json:"bots"`
		Section  string   `json:"section"`
		Bot      string   `json:"bot"`
		Model    string   `json:"model"`
		Fresh    bool     `json:"fresh_chat"`
		Message  string   `json:"message"`
		Engine   string   `json:"engine"`
		Schedule string   `json:"schedule"`
		Closed   bool     `json:"when_closed"`
		Last     int      `json:"last"`
		Title    string   `json:"title"`
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

	case "move_bots":
		var names []string
		for _, bot := range args.Bots {
			if bot = strings.TrimSpace(bot); bot != "" {
				names = append(names, bot)
			}
		}
		section := strings.TrimSpace(args.Section)
		if len(names) == 0 {
			return toolError("name at least one bot to move")
		}
		if len([]rune(section)) > 40 {
			return toolError("keep the section name under 40 characters")
		}
		if err := drop(outbox, map[string]any{
			"kind": "move_bots", "from": sender, "bots": names, "section": section,
		}); err != nil {
			return toolError("could not move them: " + err.Error())
		}
		where := "into " + section
		if section == "" {
			where = "out of their sections"
		}
		return toolText("Moving " + strings.Join(names, ", ") + " " + where + ". bupsy notes " +
			"in this chat what moved, and names any bot it could not find.")

	case "manage_bot":
		bot := strings.TrimSpace(args.Bot)
		job, role, model := strings.TrimSpace(args.Job), strings.TrimSpace(args.Role), strings.TrimSpace(args.Model)
		message, engine := strings.TrimSpace(args.Message), strings.ToLower(strings.TrimSpace(args.Engine))
		if bot == "" {
			return toolError("name the bot to change")
		}
		if job == "" && role == "" && model == "" && engine == "" && !args.Fresh && message == "" {
			return toolError("give at least one of job, role, model, engine, fresh_chat or message")
		}
		if engine != "" && engine != "claude" && engine != "codex" {
			return toolError("engine is \"claude\" or \"codex\"")
		}
		if err := drop(outbox, map[string]any{
			"kind": "manage_bot", "from": sender, "bot": bot, "job": job, "role": role,
			"model": model, "engine": engine, "fresh_chat": args.Fresh, "message": message,
		}); err != nil {
			return toolError("could not change it: " + err.Error())
		}
		return toolText("Asked bupsy to change " + bot + ". It applies the changes and notes them " +
			"in both chats, or names what it could not do (an unknown bot or model). If " + bot +
			" is working, its fresh chat and message wait until it finishes.")

	case "add_routine":
		bot, name := strings.TrimSpace(args.Bot), strings.TrimSpace(args.Name)
		message, schedule := strings.TrimSpace(args.Message), strings.Join(strings.Fields(args.Schedule), " ")
		if bot == "" || name == "" || message == "" || schedule == "" {
			return toolError("bot, name, message and schedule are all required")
		}
		if len(strings.Fields(schedule)) != 5 || strings.Contains(schedule, "/") {
			return toolError("schedule must be five-field cron without step syntax, e.g. \"0 14 * * *\"")
		}
		if len([]rune(name)) > 60 {
			return toolError("keep the name under 60 characters")
		}
		if err := drop(outbox, map[string]any{
			"kind": "add_routine", "from": sender, "bot": bot, "name": name, "message": message,
			"schedule": schedule, "when_closed": args.Closed,
		}); err != nil {
			return toolError("could not schedule it: " + err.Error())
		}
		return toolText("Asked bupsy to schedule \"" + name + "\" for " + bot + ". It notes the " +
			"routine and when it next runs in your chat, or says why it could not.")

	case "remove_routine":
		bot, name := strings.TrimSpace(args.Bot), strings.TrimSpace(args.Name)
		if bot == "" || name == "" {
			return toolError("both bot and name are required")
		}
		if err := drop(outbox, map[string]any{"kind": "remove_routine", "from": sender, "bot": bot, "name": name}); err != nil {
			return toolError("could not remove it: " + err.Error())
		}
		return toolText("Asked bupsy to remove \"" + name + "\" from " + bot + ".")

	case "stop_bot":
		bot := strings.TrimSpace(args.Bot)
		if bot == "" {
			return toolError("name the bot to stop")
		}
		if err := drop(outbox, map[string]any{"kind": "stop_bot", "from": sender, "bot": bot}); err != nil {
			return toolError("could not stop it: " + err.Error())
		}
		return toolText("Asked bupsy to stop " + bot + ". If it was not working, nothing happens.")

	case "read_chat":
		return readChat(strings.TrimSpace(args.Bot), args.Last)

	case "notify_person":
		text, title := strings.TrimSpace(args.Text), strings.TrimSpace(args.Title)
		if text == "" {
			return toolError("say what the notification is")
		}
		if err := drop(outbox, map[string]any{"kind": "notify", "from": sender, "title": title, "text": text}); err != nil {
			return toolError("could not notify: " + err.Error())
		}
		return toolText("Sent. The person sees it on their Mac when they are not looking at bupsy.")

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

// rosterBot is one bot as bupsy writes it for list_bots and read_chat: what the sidebar shows,
// whether it is working, and its routines. Nothing from any conversation.
type rosterBot struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Job        string `json:"job"`
	Section    string `json:"section"`
	Engine     string `json:"engine"`
	Model      string `json:"model"`
	Models     string `json:"models"`
	Working    bool   `json:"working"`
	Queued     int    `json:"queued"`
	LastActive string `json:"lastActive"`
	Routines   []struct {
		Name     string `json:"name"`
		Schedule string `json:"schedule"`
		Message  string `json:"message"`
		Enabled  bool   `json:"enabled"`
	} `json:"routines"`
}

func readRoster() ([]rosterBot, map[string]any) {
	if roster == "" {
		return nil, toolError("bupsy did not share the roster with this bot")
	}
	data, err := os.ReadFile(roster)
	if err != nil {
		return nil, toolError("could not read the roster: " + err.Error())
	}
	var bots []rosterBot
	if err := json.Unmarshal(data, &bots); err != nil {
		return nil, toolError("the roster file is not readable")
	}
	return bots, nil
}

// listBots reads the roster bupsy wrote, leaving out the bot asking.
func listBots() map[string]any {
	bots, problem := readRoster()
	if problem != nil {
		return problem
	}
	var lines []string
	for _, bot := range bots {
		if bot.ID != "" && bot.ID == self {
			continue
		}
		line := "- " + bot.Name
		if bot.Section != "" {
			line += " [section: " + bot.Section + "]"
		}
		if bot.Model != "" {
			line += " [model: " + bot.Model
			if bot.Engine != "" {
				line += " on " + bot.Engine
			}
			if bot.Models != "" {
				line += "; can use: " + bot.Models
			}
			line += "]"
		}
		if bot.Working {
			line += " [working now]"
		} else if bot.LastActive != "" {
			line += " [idle; last active " + bot.LastActive + "]"
		}
		if bot.Queued > 0 {
			line += fmt.Sprintf(" [%d queued]", bot.Queued)
		}
		if bot.Job != "" {
			line += ": " + bot.Job
		}
		for _, routine := range bot.Routines {
			state := ""
			if !routine.Enabled {
				state = " (paused)"
			}
			line += "\n    routine \"" + routine.Name + "\" " + routine.Schedule + state + ": " + routine.Message
		}
		lines = append(lines, line)
	}
	if len(lines) == 0 {
		return toolText("No other bots yet.")
	}
	return toolText(strings.Join(lines, "\n"))
}

// readChat returns a bot's latest messages from the snapshot bupsy saves when each of its turns
// ends, beside the roster.
func readChat(name string, last int) map[string]any {
	if name == "" {
		return toolError("name the bot whose chat to read")
	}
	bots, problem := readRoster()
	if problem != nil {
		return problem
	}
	var id, shown string
	for _, bot := range bots {
		if strings.EqualFold(bot.Name, name) && bot.ID != "" {
			id, shown = bot.ID, bot.Name
		}
	}
	if id == "" || strings.ContainsAny(id, "/\\") || strings.Contains(id, "..") {
		return toolError("no bot named " + name)
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(roster), "chats", id+".json"))
	if err != nil {
		return toolText(shown + " has no saved chat yet.")
	}
	var messages []struct {
		Who  string `json:"who"`
		Text string `json:"text"`
		At   string `json:"at"`
	}
	if err := json.Unmarshal(data, &messages); err != nil {
		return toolError("the saved chat is not readable")
	}
	if last <= 0 {
		last = 10
	}
	if last > 40 {
		last = 40
	}
	if len(messages) > last {
		messages = messages[len(messages)-last:]
	}
	var lines []string
	for _, message := range messages {
		lines = append(lines, "["+message.At+"] "+message.Who+": "+message.Text)
	}
	if len(lines) == 0 {
		return toolText(shown + " has no messages yet.")
	}
	return toolText(strings.Join(lines, "\n\n"))
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
