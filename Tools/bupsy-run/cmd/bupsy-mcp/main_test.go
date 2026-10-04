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
