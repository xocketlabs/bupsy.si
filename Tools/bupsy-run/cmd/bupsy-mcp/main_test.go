package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func callTool(t *testing.T, outbox, name string, args map[string]any) map[string]any {
	t.Helper()
	params, _ := json.Marshal(map[string]any{"name": name, "arguments": args})
	return call(params, outbox, "bot-1")
}

func dropped(t *testing.T, outbox string) []map[string]any {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(outbox, "*.json"))
	var out []map[string]any
	for _, f := range files {
		data, _ := os.ReadFile(f)
		var m map[string]any
		_ = json.Unmarshal(data, &m)
		out = append(out, m)
	}
	return out
}

func TestCreateBotOnlyAsks(t *testing.T) {
	outbox := t.TempDir()
	result := callTool(t, outbox, "create_bot", map[string]any{"name": "Researcher", "job": "Finds sources"})
	if result["isError"] == true {
		t.Fatalf("unexpected error: %v", result)
	}
	files := dropped(t, outbox)
	if len(files) != 1 || files[0]["kind"] != "create_bot" || files[0]["from"] != "bot-1" ||
		files[0]["name"] != "Researcher" || files[0]["job"] != "Finds sources" {
		t.Fatalf("wrong request dropped: %v", files)
	}
	text := result["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, "does not exist until they approve") {
		t.Fatalf("result must not claim the bot exists: %q", text)
	}
}

func TestCreateBotNeedsNameAndJob(t *testing.T) {
	outbox := t.TempDir()
	if r := callTool(t, outbox, "create_bot", map[string]any{"name": "X"}); r["isError"] != true {
		t.Fatal("missing job should be an error")
	}
	if len(dropped(t, outbox)) != 0 {
		t.Fatal("nothing should be dropped for a bad request")
	}
}

func TestMessageBotStillWorks(t *testing.T) {
	outbox := t.TempDir()
	callTool(t, outbox, "message_bot", map[string]any{"to": "Scout", "text": "hi"})
	files := dropped(t, outbox)
	if len(files) != 1 || files[0]["to"] != "Scout" || files[0]["kind"] != nil {
		t.Fatalf("message payload changed shape: %v", files)
	}
}

func TestListBotsReadsRoster(t *testing.T) {
	dir := t.TempDir()
	roster = filepath.Join(dir, "roster.json")
	defer func() { roster = "" }()
	_ = os.WriteFile(roster, []byte(`[{"name":"Scout","job":"Research"},{"name":"Inbox","job":""}]`), 0o600)
	r := callTool(t, dir, "list_bots", map[string]any{})
	text := r["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, "Scout: Research") || !strings.Contains(text, "- Inbox") {
		t.Fatalf("roster not listed: %q", text)
	}
}

func TestAskPersonDropsQuestion(t *testing.T) {
	outbox := t.TempDir()
	r := callTool(t, outbox, "ask_person", map[string]any{
		"question": "Fill the tracker?", "options": []string{"Yes", " Only clients ", ""},
	})
	if r["isError"] == true {
		t.Fatalf("unexpected error: %v", r)
	}
	files := dropped(t, outbox)
	if len(files) != 1 || files[0]["kind"] != "question" {
		t.Fatalf("no question dropped: %v", files)
	}
	options := files[0]["options"].([]any)
	if len(options) != 2 || options[1] != "Only clients" {
		t.Fatalf("options not cleaned: %v", options)
	}
}

func TestAskPersonNeedsTwoToFourOptions(t *testing.T) {
	outbox := t.TempDir()
	if r := callTool(t, outbox, "ask_person", map[string]any{"question": "Q", "options": []string{"only"}}); r["isError"] != true {
		t.Fatal("one option should be refused")
	}
	if len(dropped(t, outbox)) != 0 {
		t.Fatal("nothing should be dropped")
	}
}

func TestUpdateMeDrops(t *testing.T) {
	outbox := t.TempDir()
	r := callTool(t, outbox, "update_me", map[string]any{"name": "Researcher", "job": "Finds sources"})
	if r["isError"] == true {
		t.Fatalf("unexpected error: %v", r)
	}
	files := dropped(t, outbox)
	if len(files) != 1 || files[0]["kind"] != "update_me" || files[0]["name"] != "Researcher" {
		t.Fatalf("wrong drop: %v", files)
	}
	if r := callTool(t, t.TempDir(), "update_me", map[string]any{}); r["isError"] != true {
		t.Fatal("empty update should be refused")
	}
}

func TestMoveBotsDropsARequest(t *testing.T) {
	outbox := t.TempDir()
	result := callTool(t, outbox, "move_bots", map[string]any{
		"bots": []any{" Lead ", "QA Reviewer", ""}, "section": "Frontier & Co"})
	if result["isError"] == true {
		t.Fatalf("unexpected error: %v", result)
	}
	files := dropped(t, outbox)
	if len(files) != 1 || files[0]["kind"] != "move_bots" || files[0]["from"] != "bot-1" ||
		files[0]["section"] != "Frontier & Co" {
		t.Fatalf("wrong request dropped: %v", files)
	}
	bots, _ := files[0]["bots"].([]any)
	if len(bots) != 2 || bots[0] != "Lead" || bots[1] != "QA Reviewer" {
		t.Fatalf("bots not trimmed and filtered: %v", bots)
	}
}

func TestMoveBotsNeedsABot(t *testing.T) {
	outbox := t.TempDir()
	result := callTool(t, outbox, "move_bots", map[string]any{"bots": []any{" "}, "section": "X"})
	if result["isError"] != true || len(dropped(t, outbox)) != 0 {
		t.Fatalf("expected a refusal and nothing dropped: %v", result)
	}
}

func TestListBotsShowsSections(t *testing.T) {
	file := filepath.Join(t.TempDir(), "roster.json")
	_ = os.WriteFile(file, []byte(`[{"name":"Lead","job":"Runs it","section":"Frontier & Co"},{"name":"Scout","job":""}]`), 0o600)
	roster = file
	defer func() { roster = "" }()
	text := listBots()["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, "- Lead [section: Frontier & Co]: Runs it") || !strings.Contains(text, "- Scout") {
		t.Fatalf("roster lines wrong: %q", text)
	}
}

func TestManageBotDropsARequest(t *testing.T) {
	outbox := t.TempDir()
	result := callTool(t, outbox, "manage_bot", map[string]any{
		"bot": " Lead ", "model": "sonnet", "fresh_chat": true, "message": "Read LEAD-HANDOFF.md"})
	if result["isError"] == true {
		t.Fatalf("unexpected error: %v", result)
	}
	files := dropped(t, outbox)
	if len(files) != 1 || files[0]["kind"] != "manage_bot" || files[0]["bot"] != "Lead" ||
		files[0]["model"] != "sonnet" || files[0]["fresh_chat"] != true ||
		files[0]["message"] != "Read LEAD-HANDOFF.md" || files[0]["from"] != "bot-1" {
		t.Fatalf("wrong request dropped: %v", files)
	}
}

func TestManageBotNeedsABotAndAChange(t *testing.T) {
	for _, args := range []map[string]any{{"model": "sonnet"}, {"bot": "Lead"}, {"bot": "Lead", "fresh_chat": false}} {
		outbox := t.TempDir()
		if result := callTool(t, outbox, "manage_bot", args); result["isError"] != true || len(dropped(t, outbox)) != 0 {
			t.Fatalf("expected a refusal for %v: %v", args, result)
		}
	}
}

func TestListBotsShowsModels(t *testing.T) {
	file := filepath.Join(t.TempDir(), "roster.json")
	_ = os.WriteFile(file, []byte(`[{"name":"Lead","job":"Runs it","model":"opus","models":"default, opus, sonnet"}]`), 0o600)
	roster = file
	defer func() { roster = "" }()
	text := listBots()["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, "- Lead [model: opus; can use: default, opus, sonnet]: Runs it") {
		t.Fatalf("roster lines wrong: %q", text)
	}
}

func TestAddRoutineDropsAndChecksTheSchedule(t *testing.T) {
	outbox := t.TempDir()
	result := callTool(t, outbox, "add_routine", map[string]any{
		"bot": "Status", "name": "Start the day", "message": "start the day", "schedule": " 0  14 * * * "})
	if result["isError"] == true {
		t.Fatalf("unexpected error: %v", result)
	}
	files := dropped(t, outbox)
	if len(files) != 1 || files[0]["kind"] != "add_routine" || files[0]["schedule"] != "0 14 * * *" ||
		files[0]["when_closed"] != false {
		t.Fatalf("wrong request dropped: %v", files)
	}
	for _, schedule := range []string{"*/5 * * * *", "0 14 * *", "daily"} {
		outbox := t.TempDir()
		r := callTool(t, outbox, "add_routine", map[string]any{"bot": "S", "name": "n", "message": "m", "schedule": schedule})
		if r["isError"] != true || len(dropped(t, outbox)) != 0 {
			t.Fatalf("schedule %q should be refused", schedule)
		}
	}
}

func TestStopNotifyAndRemoveDrop(t *testing.T) {
	outbox := t.TempDir()
	callTool(t, outbox, "stop_bot", map[string]any{"bot": "Lead"})
	callTool(t, outbox, "notify_person", map[string]any{"text": "Batch done"})
	callTool(t, outbox, "remove_routine", map[string]any{"bot": "Status", "name": "Start the day"})
	kinds := map[any]bool{}
	for _, file := range dropped(t, outbox) {
		kinds[file["kind"]] = true
	}
	if !kinds["stop_bot"] || !kinds["notify"] || !kinds["remove_routine"] {
		t.Fatalf("missing drops: %v", kinds)
	}
	if r := callTool(t, t.TempDir(), "notify_person", map[string]any{"text": " "}); r["isError"] != true {
		t.Fatal("an empty notification should be refused")
	}
}

func TestManageBotChecksTheEngine(t *testing.T) {
	if r := callTool(t, t.TempDir(), "manage_bot", map[string]any{"bot": "Lead", "engine": "gpt"}); r["isError"] != true {
		t.Fatal("an unknown engine should be refused")
	}
	outbox := t.TempDir()
	callTool(t, outbox, "manage_bot", map[string]any{"bot": "Lead", "engine": "Codex"})
	if files := dropped(t, outbox); len(files) != 1 || files[0]["engine"] != "codex" {
		t.Fatalf("engine not passed on: %v", files)
	}
}

func TestListBotsLeavesOutSelfAndShowsWorkAndRoutines(t *testing.T) {
	file := filepath.Join(t.TempDir(), "roster.json")
	_ = os.WriteFile(file, []byte(`[
		{"id":"bot-1","name":"Me","job":"x"},
		{"id":"bot-2","name":"Lead","job":"Runs it","working":true,"queued":2,
		 "routines":[{"name":"Start the day","schedule":"Every day at 2pm (0 14 * * *)","message":"start","enabled":true}]}]`), 0o600)
	roster, self = file, "bot-1"
	defer func() { roster, self = "", "" }()
	text := listBots()["content"].([]any)[0].(map[string]any)["text"].(string)
	if strings.Contains(text, "Me") || !strings.Contains(text, "[working now] [2 queued]: Runs it") ||
		!strings.Contains(text, `routine "Start the day" Every day at 2pm (0 14 * * *): start`) {
		t.Fatalf("roster lines wrong: %q", text)
	}
}

func TestReadChatReadsTheSnapshot(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "roster.json")
	_ = os.WriteFile(file, []byte(`[{"id":"bot-2","name":"Lead"},{"id":"../x","name":"Sneaky"}]`), 0o600)
	_ = os.MkdirAll(filepath.Join(dir, "chats"), 0o700)
	_ = os.WriteFile(filepath.Join(dir, "chats", "bot-2.json"), []byte(
		`[{"who":"Person","text":"one","at":"9:00"},{"who":"Lead","text":"two","at":"9:01"},{"who":"Person","text":"three","at":"9:02"}]`), 0o600)
	roster = file
	defer func() { roster = "" }()
	text := readChat("lead", 2)["content"].([]any)[0].(map[string]any)["text"].(string)
	if strings.Contains(text, "one") || !strings.Contains(text, "[9:01] Lead: two") || !strings.Contains(text, "three") {
		t.Fatalf("wrong chat: %q", text)
	}
	if r := readChat("Sneaky", 5); r["isError"] != true {
		t.Fatal("an id that walks out of the folder must be refused")
	}
	if r := readChat("Nobody", 5); r["isError"] != true {
		t.Fatal("an unknown bot must be refused")
	}
}
