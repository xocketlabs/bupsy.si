package runner

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/fakeengine"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/store"
)

func TestMain(m *testing.M) {
	fakeengine.RunIfRequested()
	os.Exit(m.Run())
}

// setup makes a store with one bot and a runner whose engines are this test binary, acting as
// the fake. Returns the file the fake logs its argv to.
func setup(t *testing.T, engineID string) (*Runner, *store.Store, store.Bot, string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the approval hook is a sh script; these run on Linux and macOS")
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	argv := filepath.Join(t.TempDir(), "argv.ndjson")
	t.Setenv(fakeengine.Env, "1")
	t.Setenv("BUPSY_FAKE_LOG", argv)

	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	bot, err := st.AddBot(store.Bot{Name: "Scout", Engine: engineID, Job: "You research things."})
	if err != nil {
		t.Fatal(err)
	}
	r := New(st, Options{
		Binaries:    map[string]string{"claude": self, "codex": self},
		GateTimeout: 20,
		GateRoot:    t.TempDir(),
		Poll:        20 * time.Millisecond,
		Logf:        t.Logf,
	})
	t.Cleanup(func() { r.Close(5 * time.Second) })
	return r, st, bot, argv
}

// waitFor polls until cond holds, failing the test after a few seconds.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func kinds(thread *store.Thread) string {
	var out []string
	for _, e := range thread.Entries {
		out = append(out, e.Kind)
	}
	return strings.Join(out, ",")
}

func argvs(t *testing.T, path string) [][]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out [][]string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var args []string
		json.Unmarshal(scanner.Bytes(), &args)
		out = append(out, args)
	}
	return out
}

func indexOf(args []string, s string) int {
	for i, a := range args {
		if a == s {
			return i
		}
	}
	return -1
}

// A message runs the bot, the reply lands in the conversation, the engine's conversation id is
// kept, and the next message resumes it. The job goes before the message, and the run is gated.
func TestSendRunsAndResumes(t *testing.T) {
	r, st, bot, argv := setup(t, "claude")
	if err := r.Send(bot.ID, "hello"); err != nil {
		t.Fatal(err)
	}
	r.Wait(bot.ID)
	thread, _ := r.Thread(bot.ID)
	if got := kinds(thread); got != "you,bot" {
		t.Fatalf("entries %s", got)
	}
	if thread.Entries[1].Text != "echo: hello" {
		t.Errorf("reply %q", thread.Entries[1].Text)
	}
	saved, _ := st.Bot(bot.ID)
	if saved.Conversation != "fake-session-1" {
		t.Fatalf("conversation id %q was not kept", saved.Conversation)
	}

	if err := r.Send(bot.ID, "again"); err != nil {
		t.Fatal(err)
	}
	r.Wait(bot.ID)
	runs := argvs(t, argv)
	if len(runs) != 2 {
		t.Fatalf("%d runs", len(runs))
	}
	if first := runs[0]; first[1] != "You research things.\n\nhello" || indexOf(first, "--settings") < 0 {
		t.Errorf("first run argv %q: want the job before the message, and the gate installed", first)
	}
	if i := indexOf(runs[1], "--resume"); i < 0 || runs[1][i+1] != "fake-session-1" {
		t.Errorf("second run argv %q did not resume the conversation", runs[1])
	}
	if s := r.State(saved); s.Running || s.Mood != "done" || !s.Unread || s.Preview != "echo: again" {
		t.Errorf("state after a run: %+v", s)
	}
	r.MarkRead(bot.ID)
	saved, _ = st.Bot(bot.ID)
	if s := r.State(saved); s.Unread || s.Mood != "idle" {
		t.Errorf("state after reading: %+v", s)
	}
}

// The heart of it: a tool call that needs approval appears as a card, the person's answer goes
// back through the real hook script, and the engine does what it was told.
func TestApprovalAllowedAndDenied(t *testing.T) {
	for _, allow := range []bool{true, false} {
		t.Run(map[bool]string{true: "allowed", false: "denied"}[allow], func(t *testing.T) {
			r, st, bot, _ := setup(t, "claude")
			if err := r.Send(bot.ID, "please [tool]"); err != nil {
				t.Fatal(err)
			}
			var approvalID string
			waitFor(t, "an approval card", func() bool {
				thread, _ := r.Thread(bot.ID)
				if ids := thread.Undecided(); len(ids) == 1 {
					approvalID = ids[0]
					return true
				}
				return false
			})
			live, _ := st.Bot(bot.ID)
			if s := r.State(live); !s.NeedsYou || s.Mood != "waitingForYou" || !s.Running {
				t.Errorf("state while waiting: %+v", s)
			}
			thread, _ := r.Thread(bot.ID)
			card, _ := thread.Approval(approvalID)
			if card.Tool != "Bash" || card.Summary != "echo fake" || card.Reason == "" {
				t.Errorf("card %+v", card)
			}

			if err := r.Decide(bot.ID, approvalID, allow); err != nil {
				t.Fatal(err)
			}
			r.Wait(bot.ID)
			// Answering twice is refused, and says so.
			if err := r.Decide(bot.ID, approvalID, !allow); !errors.Is(err, ErrAnswered) {
				t.Errorf("second answer: %v", err)
			}

			thread, _ = r.Thread(bot.ID)
			if got := kinds(thread); got != "you,tool,approval,bot" {
				t.Fatalf("entries %s", got)
			}
			card, _ = thread.Approval(approvalID)
			tool := thread.Entries[1].Tool
			reply := thread.Entries[3].Text
			if allow {
				if card.Decided != store.Allowed || tool.Failed || reply != "I ran it." {
					t.Errorf("allowed: card %q, tool failed %v, reply %q", card.Decided, tool.Failed, reply)
				}
			} else {
				if card.Decided != store.Denied || !tool.Failed || reply != "I wasn't allowed to run it." {
					t.Errorf("denied: card %q, tool failed %v, reply %q", card.Decided, tool.Failed, reply)
				}
			}
			if tool.Verb != "ran" || tool.Target != "echo fake" {
				t.Errorf("tool step %+v", tool)
			}
		})
	}
}

// Policy decides before a person is asked: a bot on auto is never asked, and the audit line
// still records the call.
func TestPolicyAllowsWithoutAsking(t *testing.T) {
	r, st, bot, _ := setup(t, "claude")
	if _, err := st.UpdateBot(bot.ID, func(b *store.Bot) { b.Autonomy = engine.AutonomyAuto }); err != nil {
		t.Fatal(err)
	}
	r.Send(bot.ID, "[tool]")
	r.Wait(bot.ID)
	thread, _ := r.Thread(bot.ID)
	if got := kinds(thread); got != "you,tool,bot" || thread.Entries[2].Text != "I ran it." {
		t.Fatalf("entries %s", got)
	}
	records, _ := st.Load(bot.ID)
	audited := false
	for _, rec := range records {
		if rec.Type == store.RecordGate && rec.Tool == "Bash" && rec.Decision == store.Allowed && rec.Rule == "autonomy: auto" {
			audited = true
		}
	}
	if !audited {
		t.Error("a call allowed by policy left no audit line")
	}
}

// Stop ends the run and everything it started; a card waiting at the time settles as expired,
// and a message queued behind the run is dropped rather than started.
func TestStop(t *testing.T) {
	r, st, bot, _ := setup(t, "claude")
	r.Send(bot.ID, "[sleep]")
	r.Send(bot.ID, "queued behind it")
	waitFor(t, "the run to start", func() bool { live, _ := st.Bot(bot.ID); return r.State(live).Running })
	started := time.Now()
	if err := r.Stop(bot.ID); err != nil {
		t.Fatal(err)
	}
	r.Wait(bot.ID)
	if time.Since(started) > 8*time.Second {
		t.Errorf("stop took %v", time.Since(started))
	}
	thread, _ := r.Thread(bot.ID)
	if got := kinds(thread); got != "you,you,note" {
		t.Errorf("entries %s: want both messages and a Stopped note, no failure, no queued run", got)
	}
	live, _ := st.Bot(bot.ID)
	if s := r.State(live); s.Running || s.Mood == "failed" {
		t.Errorf("state after stop: %+v", s)
	}
}

// A message sent while the bot works waits, then goes in one turn with any others.
func TestQueuedMessagesGoTogether(t *testing.T) {
	r, _, bot, argv := setup(t, "claude")
	r.Send(bot.ID, "please [tool]")
	waitFor(t, "an approval card", func() bool { th, _ := r.Thread(bot.ID); return len(th.Undecided()) == 1 })
	r.Send(bot.ID, "one")
	r.Send(bot.ID, "two")
	th, _ := r.Thread(bot.ID)
	r.Decide(bot.ID, th.Undecided()[0], true)
	r.Wait(bot.ID)
	runs := argvs(t, argv)
	if len(runs) != 2 || !strings.HasSuffix(runs[1][1], "one\n\ntwo") {
		t.Fatalf("runs %q", runs)
	}
}

// A conversation read back after a crash settles what nobody can answer any more.
func TestReloadSettlesADeadRun(t *testing.T) {
	r, st, bot, _ := setup(t, "claude")
	at := time.Now().UTC()
	st.Append(bot.ID, store.Record{Type: store.RecordRun, Run: "r1", Status: store.RunStarted, At: at})
	st.Append(bot.ID, store.Record{Type: store.RecordEntry, At: at, Entry: &store.Entry{
		ID: "e1", Kind: store.KindApproval, At: at, Approval: &store.Approval{ID: "1-2-3", Tool: "Bash"}}})
	thread, _ := r.Thread(bot.ID)
	if card, _ := thread.Approval("1-2-3"); card.Decided != store.Expired {
		t.Errorf("an approval from a dead run reads as %q", card.Decided)
	}
	if err := r.Decide(bot.ID, "1-2-3", true); !errors.Is(err, ErrAnswered) {
		t.Errorf("answered a dead run's approval: %v", err)
	}
	live, _ := st.Bot(bot.ID)
	if s := r.State(live); s.NeedsYou || s.Mood != "failed" {
		t.Errorf("state %+v", s)
	}
}

func TestFailuresAreShown(t *testing.T) {
	r, st, bot, _ := setup(t, "claude")
	r.Send(bot.ID, "[fail]")
	r.Wait(bot.ID)
	thread, _ := r.Thread(bot.ID)
	if got := kinds(thread); !strings.HasSuffix(got, "failure") {
		t.Errorf("entries %s", got)
	}
	live, _ := st.Bot(bot.ID)
	if s := r.State(live); s.Mood != "failed" {
		t.Errorf("mood %q", s.Mood)
	}

	// An engine that is not installed fails closed, saying what to do.
	r2, _, bot2, _ := setup(t, "claude")
	r2.opts.Binaries["claude"] = filepath.Join(t.TempDir(), "no-such-claude")
	r2.Send(bot2.ID, "hi")
	r2.Wait(bot2.ID)
	thread, _ = r2.Thread(bot2.ID)
	if last := thread.Entries[len(thread.Entries)-1]; last.Kind != store.KindFailure || !strings.Contains(last.Text, "--claude-binary") {
		t.Errorf("missing engine: %+v", last)
	}
}

func TestCodexRunsWithoutAGate(t *testing.T) {
	r, st, bot, argv := setup(t, "codex")
	r.Send(bot.ID, "hello")
	r.Wait(bot.ID)
	thread, _ := r.Thread(bot.ID)
	if got := kinds(thread); got != "you,bot" {
		t.Fatalf("entries %s", got)
	}
	saved, _ := st.Bot(bot.ID)
	if saved.Conversation != "fake-thread-1" {
		t.Errorf("thread id %q", saved.Conversation)
	}
	run := argvs(t, argv)[0]
	if run[0] != "exec" || indexOf(run, "read-only") < 0 {
		t.Errorf("codex argv %q: an ask bot should get the read-only sandbox", run)
	}
}
