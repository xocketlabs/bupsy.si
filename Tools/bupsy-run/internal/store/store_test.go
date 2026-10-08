package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
)

func TestBotsRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	scout, err := s.AddBot(Bot{Name: " Scout ", Engine: "claude", Job: "Research."})
	if err != nil {
		t.Fatal(err)
	}
	if scout.Name != "Scout" || scout.Autonomy != engine.AutonomyAsk || scout.Colour == "" || !ValidID(scout.ID) {
		t.Errorf("defaults not filled in: %+v", scout)
	}
	if _, err := s.AddBot(Bot{Name: "scout", Engine: "codex"}); err == nil {
		t.Error("two bots share a name, so a message to one is ambiguous")
	}
	for _, bad := range []Bot{
		{Name: "", Engine: "claude"},
		{Name: "X", Engine: "gpt"},
		{Name: "Y", Engine: "codex", Autonomy: "write"},
	} {
		if _, err := s.AddBot(bad); err == nil {
			t.Errorf("accepted %+v", bad)
		}
	}
	if _, err := s.UpdateBot(scout.ID, func(b *Bot) { b.Conversation = "sess-1" }); err != nil {
		t.Fatal(err)
	}

	// A second process sees the first's bots, and its new bot appears to the first without a
	// restart — which is how `bupsy-desktop --new-bot` reaches a running app.
	other, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if bots := other.Bots(); len(bots) != 1 || bots[0].Conversation != "sess-1" {
		t.Fatalf("reopened store has %+v", bots)
	}
	if _, err := other.AddBot(Bot{Name: "Inbox", Engine: "codex"}); err != nil {
		t.Fatal(err)
	}
	if bots := s.Bots(); len(bots) != 2 || bots[0].Name != "Scout" || bots[1].Name != "Inbox" {
		t.Errorf("first store sees %+v", bots)
	}
}

// The log is append-only: a decision is a new line, the original approval line is untouched, and
// a torn final line from a crash costs only itself.
func TestLogIsAppendOnlyAndFolds(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	bot, err := s.AddBot(Bot{Name: "Scout", Engine: "claude"})
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	records := []Record{
		{Type: RecordEntry, At: at, Entry: &Entry{ID: "e1", Kind: KindYou, At: at, Text: "hi"}},
		{Type: RecordRun, At: at, Run: "r1", Status: RunStarted},
		{Type: RecordEngine, At: at, Run: "r1", Event: &engine.Event{Kind: engine.KindStarted, ConversationID: "s"}},
		{Type: RecordEntry, At: at, Entry: &Entry{ID: "e2", Kind: KindTool, At: at,
			Tool: &Tool{CallID: "c1", Name: "Bash", Verb: "ran", Target: "ls"}}},
		{Type: RecordEntry, At: at, Entry: &Entry{ID: "e3", Kind: KindApproval, At: at,
			Approval: &Approval{ID: "g1", Tool: "Bash", Summary: "ls", Reason: "asks"}}},
		{Type: RecordDecided, At: at, Ref: "g1", Decision: Denied},
		{Type: RecordDecided, At: at, Ref: "g1", Decision: Expired}, // too late; first wins
		{Type: RecordToolFailed, At: at, Ref: "c1"},
		{Type: RecordRun, At: at, Run: "r1", Status: RunFinished},
	}
	for _, record := range records {
		if err := s.Append(bot.ID, record); err != nil {
			t.Fatal(err)
		}
	}
	log := filepath.Join(s.Dir(), "bots", bot.ID, "log.ndjson")
	before, _ := os.ReadFile(log)
	// A crash mid-write.
	f, _ := os.OpenFile(log, os.O_WRONLY|os.O_APPEND, 0)
	f.WriteString(`{"type":"entry","entry":{"id":"e4","ki`)
	f.Close()

	loaded, err := s.Load(bot.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded) != len(records) {
		t.Fatalf("loaded %d records, want %d", len(loaded), len(records))
	}
	thread := Fold(loaded)
	if len(thread.Entries) != 3 || thread.LastRun != RunFinished {
		t.Fatalf("thread = %+v", thread)
	}
	if a, _ := thread.Approval("g1"); a.Decided != Denied {
		t.Errorf("approval decided %q, want denied", a.Decided)
	}
	if !thread.Entries[1].Tool.Failed {
		t.Error("tool failure not folded in")
	}
	if len(thread.Undecided()) != 0 {
		t.Error("a decided approval still reads as waiting")
	}
	after, _ := os.ReadFile(log)
	if !strings.HasPrefix(string(after), string(before)) {
		t.Error("an earlier line of the log was rewritten")
	}

	// A clone is independent of further appends.
	clone := thread.Clone()
	thread.Apply(Record{Type: RecordEntry, Entry: &Entry{ID: "e5", Kind: KindBot, Text: "later"}})
	if len(clone.Entries) != 3 {
		t.Error("a clone changed when the thread did")
	}
	if a, ok := clone.Approval("g1"); !ok || a.Decided != Denied {
		t.Error("a clone lost its index")
	}
}

func TestIDsCannotLeaveTheStore(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"../x", "..", "a/b", `a\b`, "", "ZZZ"} {
		if err := s.Append(id, Record{Type: RecordRun}); err == nil {
			t.Errorf("Append accepted bot id %q", id)
		}
		if _, err := s.Load(id); err == nil {
			t.Errorf("Load accepted bot id %q", id)
		}
	}
	if !ValidID(NewID()) {
		t.Error("NewID makes ids ValidID refuses")
	}
}

func TestFilesArePrivate(t *testing.T) {
	if os.Getenv("GOOS") == "windows" || filepath.Separator == '\\' {
		t.Skip("Windows has no Unix permission bits")
	}
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	bot, _ := s.AddBot(Bot{Name: "Scout", Engine: "claude"})
	s.Append(bot.ID, Record{Type: RecordRun})
	for _, name := range []string{"bot.json", "log.ndjson"} {
		info, err := os.Stat(filepath.Join(s.Dir(), "bots", bot.ID, name))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s is %v; other users can read a conversation", name, info.Mode().Perm())
		}
	}
}
