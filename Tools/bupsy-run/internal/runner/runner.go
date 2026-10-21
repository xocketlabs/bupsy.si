// Package runner runs bots: it takes a message, runs the bot's engine on it behind the approval
// gate, and turns what the engine says into the conversation a person reads.
//
// It is the desktop app's equivalent of the Mac's AppModel run loop, built only from the
// headless core's own parts — engine adapters, host, gate — so a bot run here is held to the same
// rules as one run on a Mac: the same argv, the same hook, the same policy, the same fail-closed
// behaviour when something is missing.
package runner

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/gate"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/host"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/store"
)

// Options tune a Runner. The zero value is right for the app; tests change the timings.
type Options struct {
	// Binaries points an engine at a specific binary, by engine id. An engine not listed is
	// found on PATH and in the usual install locations.
	Binaries map[string]string
	// GateTimeout is how long, in seconds, the hook waits for a person before denying by itself.
	// Zero means gate.ScriptTimeoutSeconds.
	GateTimeout int
	// GateRoot is where each run's gate directory is made. Empty means the system temp folder.
	GateRoot string
	// Workspaces is where a bot with no folder of its own gets one.
	Workspaces string
	// Poll is how often the gate directory is checked. Zero means 200ms, as on the Mac.
	Poll time.Duration
	// Logf reports problems nobody is waiting on, such as a log line that would not save.
	Logf func(format string, args ...any)
}

// Errors the API turns into answers the person reads.
var (
	ErrNoBot    = errors.New("no such bot")
	ErrAnswered = errors.New("that request was already answered")
	ErrEmpty    = errors.New("write something first")
)

// Runner runs bots and holds their conversations.
type Runner struct {
	store *store.Store
	opts  Options

	mu      sync.Mutex
	threads map[string]*store.Thread
	runs    map[string]*activeRun
	queued  map[string][]string
	closed  bool
}

// activeRun is one engine process and the gate in front of it.
type activeRun struct {
	id      string
	cancel  context.CancelFunc
	watcher *gate.Watcher
	// pending is approvals waiting on a person, by gate request id.
	pending map[string]bool
	stopped bool
	failed  bool
	// finished is set once the run has been closed. The gate's poll can deliver one last request
	// after that, and it must be refused rather than raise a card nobody can answer.
	finished bool
	done     chan struct{}
}

// New makes a Runner over a store.
func New(st *store.Store, opts Options) *Runner {
	if opts.GateTimeout == 0 {
		opts.GateTimeout = gate.ScriptTimeoutSeconds
	}
	if opts.Poll == 0 {
		opts.Poll = 200 * time.Millisecond
	}
	if opts.Workspaces == "" {
		opts.Workspaces = filepath.Join(st.Dir(), "workspaces")
	}
	if opts.Logf == nil {
		opts.Logf = log.Printf
	}
	return &Runner{
		store:   st,
		opts:    opts,
		threads: map[string]*store.Thread{},
		runs:    map[string]*activeRun{},
		queued:  map[string][]string{},
	}
}

// Send gives a bot a message. If it is already working, the message waits and goes with any
// others in one turn when this one finishes, as on the Mac.
func (r *Runner) Send(botID, text string) error {
	text = strings.TrimSpace(text)
	if text == "" {
		return ErrEmpty
	}
	bot, ok := r.store.Bot(botID)
	if !ok {
		return ErrNoBot
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return errors.New("bupsy is closing")
	}
	r.thread(botID)
	r.entry(botID, store.Entry{Kind: store.KindYou, Text: text})
	if r.runs[botID] != nil {
		r.queued[botID] = append(r.queued[botID], text)
		return nil
	}
	r.start(bot, text)
	return nil
}

// Decide answers an approval card.
//
// Only a request still waiting, on a gate still open, can be answered. Anything else settles as
// expired and reports ErrAnswered: a late Allow must never read as if it took effect.
func (r *Runner) Decide(botID, approvalID string, allow bool) error {
	if _, ok := r.store.Bot(botID); !ok {
		return ErrNoBot
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	thread := r.thread(botID)
	approval, ok := thread.Approval(approvalID)
	if !ok || approval.Decided != "" {
		return ErrAnswered
	}
	run := r.runs[botID]
	if run == nil || !run.pending[approvalID] || run.watcher.Expired(approvalID) {
		if run != nil {
			delete(run.pending, approvalID)
		}
		r.append(botID, store.Record{Type: store.RecordDecided, Ref: approvalID, Decision: store.Expired})
		return ErrAnswered
	}
	reason := "you approved it"
	if !allow {
		reason = "you declined it"
	}
	if err := run.watcher.Decide(approvalID, allow, reason); err != nil {
		return err
	}
	delete(run.pending, approvalID)
	decision := store.Allowed
	if !allow {
		decision = store.Denied
	}
	r.append(botID, store.Record{Type: store.RecordDecided, Ref: approvalID, Decision: decision})
	return nil
}

// Answer records the answer to a question card. Bots ask through bupsy's MCP server, which the
// desktop app does not connect yet, so in practice there are none to answer; the route exists so
// the shared web app gets a truthful "already answered" rather than a 404.
func (r *Runner) Answer(botID, questionID, answer string) error {
	if _, ok := r.store.Bot(botID); !ok {
		return ErrNoBot
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.thread(botID).OpenQuestion(questionID) {
		return ErrAnswered
	}
	r.append(botID, store.Record{Type: store.RecordAnswered, Ref: questionID, Text: answer})
	return nil
}

// Stop ends a bot's run, and drops anything queued behind it.
func (r *Runner) Stop(botID string) error {
	if _, ok := r.store.Bot(botID); !ok {
		return ErrNoBot
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.stop(botID)
	return nil
}

func (r *Runner) stop(botID string) {
	delete(r.queued, botID)
	run := r.runs[botID]
	if run == nil || run.stopped {
		return
	}
	run.stopped = true
	// Answer anything the hook is holding first, so it lets go at once rather than at the end
	// of its wait. The cards themselves settle as expired when the run finishes.
	for id := range run.pending {
		_ = run.watcher.Decide(id, false, "the run was stopped")
	}
	run.cancel()
}

// Close stops every run and waits for them to finish, up to a limit.
func (r *Runner) Close(wait time.Duration) {
	r.mu.Lock()
	r.closed = true
	var done []chan struct{}
	for id, run := range r.runs {
		r.stop(id)
		done = append(done, run.done)
	}
	r.mu.Unlock()
	deadline := time.After(wait)
	for _, ch := range done {
		select {
		case <-ch:
		case <-deadline:
			return
		}
	}
}

// Wait blocks until a bot has no run going, including any queued behind the current one.
func (r *Runner) Wait(botID string) {
	for {
		r.mu.Lock()
		run := r.runs[botID]
		r.mu.Unlock()
		if run == nil {
			return
		}
		<-run.done
	}
}

// Thread returns a copy of a bot's conversation.
func (r *Runner) Thread(botID string) (*store.Thread, error) {
	if _, ok := r.store.Bot(botID); !ok {
		return nil, ErrNoBot
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.thread(botID).Clone(), nil
}

// State is how a bot is doing, as the sidebar shows it.
type State struct {
	Running  bool
	NeedsYou bool
	// Mood is the Mac's BotMood by name: idle, working, waitingForYou, done or failed.
	Mood    string
	Unread  bool
	Preview string
}

// State reports how a bot is doing.
func (r *Runner) State(bot store.Bot) State {
	r.mu.Lock()
	defer r.mu.Unlock()
	thread := r.thread(bot.ID)
	state := State{Running: r.runs[bot.ID] != nil}
	state.NeedsYou = len(thread.Undecided()) > 0
	for _, entry := range thread.Entries {
		if entry.Question != nil && entry.Question.Answer == "" {
			state.NeedsYou = true
		}
	}
	if n := len(thread.Entries); n > 0 {
		last := thread.Entries[n-1]
		state.Unread = last.Kind != store.KindYou && last.At.After(bot.LastRead)
	}
	state.Preview = preview(thread)
	switch {
	case state.NeedsYou:
		state.Mood = "waitingForYou"
	case state.Running:
		state.Mood = "working"
	case thread.LastRun == store.RunFailed:
		state.Mood = "failed"
	case state.Unread:
		state.Mood = "done"
	default:
		state.Mood = "idle"
	}
	return state
}

// MarkRead records that the person has seen a bot's conversation as it now stands.
func (r *Runner) MarkRead(botID string) {
	bot, ok := r.store.Bot(botID)
	if !ok || !r.State(bot).Unread {
		// Only when something changes: the page polls every second or two, and rewriting the
		// bot's file on each poll would be all cost and no information.
		return
	}
	if _, err := r.store.UpdateBot(botID, func(b *store.Bot) { b.LastRead = time.Now().UTC() }); err != nil {
		r.opts.Logf("bupsy: marking %s read: %v", botID, err)
	}
}

// preview is the line under a bot's name: the last thing said, on one line.
func preview(thread *store.Thread) string {
	for i := len(thread.Entries) - 1; i >= 0; i-- {
		entry := thread.Entries[i]
		switch entry.Kind {
		case store.KindYou, store.KindBot, store.KindFrom, store.KindFailure:
			text := strings.Join(strings.Fields(entry.Text), " ")
			if runes := []rune(text); len(runes) > 120 {
				text = string(runes[:119]) + "…"
			}
			if text != "" {
				return text
			}
		}
	}
	return ""
}

// thread returns a bot's conversation, reading it from disk the first time. Callers hold r.mu.
//
// A conversation read back from disk can hold the remains of a run this process did not finish:
// approvals nobody can answer any more, and a run that started but never ended. Both are settled
// here, in the log, so the cards stop offering an Allow that would do nothing.
func (r *Runner) thread(botID string) *store.Thread {
	if thread, ok := r.threads[botID]; ok {
		return thread
	}
	records, err := r.store.Load(botID)
	if err != nil {
		r.opts.Logf("bupsy: reading %s's conversation: %v", botID, err)
	}
	thread := store.Fold(records)
	r.threads[botID] = thread
	if r.runs[botID] == nil {
		for _, id := range thread.Undecided() {
			r.append(botID, store.Record{Type: store.RecordDecided, Ref: id, Decision: store.Expired})
		}
		if thread.LastRun == store.RunStarted {
			r.append(botID, store.Record{Type: store.RecordRun, Status: store.RunFailed})
			r.entry(botID, store.Entry{Kind: store.KindNote, Text: "Bupsy closed while this was running."})
		}
	}
	return thread
}

// append writes a record and folds it into the live thread. Callers hold r.mu.
func (r *Runner) append(botID string, record store.Record) {
	if record.At.IsZero() {
		record.At = time.Now().UTC()
	}
	// Shown even if it could not be saved: losing it from the screen too would hide the problem.
	if err := r.store.Append(botID, record); err != nil {
		r.opts.Logf("bupsy: saving to %s's conversation: %v", botID, err)
	}
	if thread, ok := r.threads[botID]; ok {
		thread.Apply(record)
	}
}

// entry appends a visible line. Callers hold r.mu.
func (r *Runner) entry(botID string, entry store.Entry) {
	entry.ID = store.NewID()
	entry.At = time.Now().UTC()
	r.append(botID, store.Record{Type: store.RecordEntry, At: entry.At, Entry: &entry})
}

// start begins a run. Callers hold r.mu.
func (r *Runner) start(bot store.Bot, text string) {
	ctx, cancel := context.WithCancel(context.Background())
	run := &activeRun{
		id:      store.NewID(),
		cancel:  cancel,
		pending: map[string]bool{},
		done:    make(chan struct{}),
	}
	r.runs[bot.ID] = run
	r.append(bot.ID, store.Record{Type: store.RecordRun, Run: run.id, Status: store.RunStarted})
	go r.execute(ctx, bot, text, run)
}

func (r *Runner) execute(ctx context.Context, bot store.Bot, text string, run *activeRun) {
	defer r.finish(bot.ID, run)

	adapter, binary := r.adapter(bot.Engine)
	req := engine.Request{
		// The job goes before every message, as the Mac does, rather than once at the start: a
		// bot resumed weeks later still knows what it is for.
		Prompt:   text,
		Resume:   bot.Conversation,
		Model:    bot.Model,
		Autonomy: bot.Autonomy,
	}
	if job := strings.TrimSpace(bot.Job); job != "" {
		req.Prompt = job + "\n\n" + text
	}

	workdir, err := r.workdir(bot)
	if err != nil {
		r.fail(bot.ID, run, fmt.Sprintf("%s's folder isn't usable: %v", bot.Name, err))
		return
	}
	req.WorkingDir = workdir

	if bot.Engine == "claude" {
		// Claude takes its approvals from the gate. Without one it would fall back on the
		// person's own Claude Code permissions and run whatever those allow, unasked — so a gate
		// that cannot be set up fails the run rather than running it ungated.
		settings, err := r.openGate(ctx, bot, run)
		if err != nil {
			r.fail(bot.ID, run, fmt.Sprintf("The approval gate couldn't be set up, so %s didn't run: %v", bot.Name, err))
			return
		}
		req.GateSettings = settings
	}

	if local, ok := adapter.(engine.Local); ok {
		// Checked against what Ollama or LM Studio has installed right now: Codex downloads a
		// model it is not given, or one the provider does not have, without asking.
		if req, err = local.Prepare(ctx, req); err != nil {
			r.fail(bot.ID, run, fmt.Sprintf("%s didn't run: %v.", bot.Name, err))
			return
		}
	}

	name, args := adapter.Command(req)
	path, err := host.Resolve(name)
	if err != nil {
		flag := "--" + binary + "-binary"
		r.fail(bot.ID, run, fmt.Sprintf("%s isn't installed, or Bupsy can't find it. Install it and "+
			"sign in, or start Bupsy with %s pointing at it.", binary, flag))
		return
	}

	err = host.RunResolved(ctx, path, args, adapter, req, func(event engine.Event) {
		r.event(bot, run, event)
	})
	if err != nil && ctx.Err() == nil {
		r.fail(bot.ID, run, err.Error())
	}
}

// openGate installs a fresh gate for one run and starts watching it.
//
// A fresh directory per run, never a shared one, as on the Mac: two runs starting together must
// not read each other's requests.
func (r *Runner) openGate(ctx context.Context, bot store.Bot, run *activeRun) (string, error) {
	if runtime.GOOS == "windows" && !gitBashAvailable() {
		// The hook is a sh script, and on Windows Claude Code runs hooks with Git Bash. If it
		// cannot, the hook fails to start — a non-blocking error, so every call would proceed
		// ungated. Refused here instead.
		return "", errors.New("Git for Windows (Git Bash) is needed to run the approval hook; install it from git-scm.com")
	}
	dir, err := os.MkdirTemp(r.opts.GateRoot, "bupsy-gate-")
	if err != nil {
		return "", err
	}
	settings, err := gate.Install(dir, r.opts.GateTimeout)
	if err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	watcher, err := gate.NewWatcher(dir)
	if err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	r.mu.Lock()
	run.watcher = watcher
	r.mu.Unlock()
	go watcher.Watch(ctx, r.opts.Poll,
		func(request gate.Request) { r.gateRequest(bot.ID, run, request) },
		func(id string) { r.gateExpired(bot.ID, run, id) })
	return settings, nil
}

// gateRequest decides a tool call by policy, or puts it in front of the person.
func (r *Runner) gateRequest(botID string, run *activeRun, request gate.Request) {
	// Read fresh for every call: lowering a bot's trust applies to the run already going, not
	// just the next one.
	bot, ok := r.store.Bot(botID)
	if !ok {
		_ = run.watcher.Decide(request.ID, false, "The bot was deleted.")
		return
	}
	outcome := gate.Decide(request.Tool, bot.Autonomy, bot.Allowlist)
	r.mu.Lock()
	defer r.mu.Unlock()
	if run.stopped || run.finished {
		_ = run.watcher.Decide(request.ID, false, "the run was stopped")
		return
	}
	if outcome.Allow {
		if err := run.watcher.Decide(request.ID, true, outcome.Rule); err != nil {
			r.opts.Logf("bupsy: answering the gate: %v", err)
		}
		r.append(botID, store.Record{Type: store.RecordGate, Ref: request.ID, Tool: request.Tool,
			Decision: store.Allowed, Rule: outcome.Rule})
		return
	}
	run.pending[request.ID] = true
	r.entry(botID, store.Entry{Kind: store.KindApproval, Approval: &store.Approval{
		ID: request.ID, Tool: request.Tool, Summary: clip(request.Summary(), 500), Reason: outcome.Reason,
	}})
}

// gateExpired settles a card the hook gave up on: it waited its full time and denied the call.
func (r *Runner) gateExpired(botID string, run *activeRun, id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !run.pending[id] {
		return
	}
	delete(run.pending, id)
	r.append(botID, store.Record{Type: store.RecordDecided, Ref: id, Decision: store.Expired})
}

// event records one engine event and turns it into what the person sees.
func (r *Runner) event(bot store.Bot, run *activeRun, event engine.Event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	copied := event
	r.append(bot.ID, store.Record{Type: store.RecordEngine, Run: run.id, Event: &copied})

	switch event.Kind {
	case engine.KindStarted, engine.KindDone:
		// The resume handle, kept as soon as it is known: a run that fails halfway is still a
		// conversation the next message should continue.
		if id := event.ConversationID; id != "" {
			if _, err := r.store.UpdateBot(bot.ID, func(b *store.Bot) { b.Conversation = id }); err != nil {
				r.opts.Logf("bupsy: saving %s's conversation id: %v", bot.ID, err)
			}
		}
	case engine.KindText:
		r.entry(bot.ID, store.Entry{Kind: store.KindBot, Text: event.Text})
	case engine.KindToolCall:
		target := gate.Request{Tool: event.Name, Input: event.Arguments}.Summary()
		if target == event.Name {
			target = ""
		}
		r.entry(bot.ID, store.Entry{Kind: store.KindTool, Tool: &store.Tool{
			CallID: event.CallID, Name: event.Name, Verb: Verb(event.Name), Target: clip(target, 300),
		}})
	case engine.KindToolResult:
		if event.IsError != nil && *event.IsError && event.CallID != "" {
			r.append(bot.ID, store.Record{Type: store.RecordToolFailed, Ref: event.CallID})
		}
	case engine.KindFailed:
		run.failed = true
		// A run the person stopped exits non-zero; saying it "failed" would be untrue.
		if !run.stopped {
			message := event.Message
			if event.FailureKind == "notSignedIn" {
				message = bot.Engine + " isn't signed in. Run `" + bot.Engine + "` in a terminal once to sign in, then try again."
			}
			r.entry(bot.ID, store.Entry{Kind: store.KindFailure, Text: message})
		}
	}
}

// fail records a run that could not get going.
func (r *Runner) fail(botID string, run *activeRun, message string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	run.failed = true
	r.entry(botID, store.Entry{Kind: store.KindFailure, Text: message})
}

// finish closes a run: its cards settle, its gate goes, and anything queued starts.
func (r *Runner) finish(botID string, run *activeRun) {
	run.cancel()
	r.mu.Lock()
	defer r.mu.Unlock()
	run.finished = true
	// Nothing can answer these any more, so the cards settle instead of offering an Allow that
	// does nothing.
	for id := range run.pending {
		r.append(botID, store.Record{Type: store.RecordDecided, Ref: id, Decision: store.Expired})
	}
	run.pending = map[string]bool{}
	status := store.RunFinished
	switch {
	case run.stopped:
		status = store.RunStopped
		r.entry(botID, store.Entry{Kind: store.KindNote, Text: "Stopped."})
	case run.failed:
		status = store.RunFailed
	}
	r.append(botID, store.Record{Type: store.RecordRun, Run: run.id, Status: status})
	if run.watcher != nil {
		// Best effort: a hook still holding a file open on Windows can refuse this, and a few
		// leftover bytes in the temp folder are not worth failing over.
		_ = os.RemoveAll(run.watcher.Dir())
	}
	delete(r.runs, botID)

	if queued := r.queued[botID]; len(queued) > 0 && !r.closed {
		delete(r.queued, botID)
		if bot, ok := r.store.Bot(botID); ok {
			r.start(bot, strings.Join(queued, "\n\n"))
		}
	}
	close(run.done)
}

func (r *Runner) adapter(id string) (engine.Adapter, string) {
	binary := r.opts.Binaries[id]
	switch id {
	case "codex":
		return engine.Codex{Binary: binary}, "codex"
	case "local":
		// Codex's local mode, so the codex binary.
		return engine.Local{Binary: r.opts.Binaries["codex"]}, "codex"
	default:
		return engine.Claude{Binary: binary}, "claude"
	}
}

// workdir is the folder a bot works in: its own, or one made for it.
//
// A bot with no folder gets an empty one of its own rather than the folder Bupsy happened to be
// started from, which for an app launched from a menu is somewhere arbitrary — and for codex,
// whose sandbox is scoped to the working folder, that choice is the bot's reach.
func (r *Runner) workdir(bot store.Bot) (string, error) {
	if bot.Workdir != "" {
		info, err := os.Stat(bot.Workdir)
		if err != nil {
			return "", err
		}
		if !info.IsDir() {
			return "", fmt.Errorf("%s is not a folder", bot.Workdir)
		}
		return bot.Workdir, nil
	}
	dir := filepath.Join(r.opts.Workspaces, bot.ID)
	return dir, os.MkdirAll(dir, 0o700)
}

// gitBashAvailable reports whether a sh for the hook can be found on Windows: Claude Code's own
// setting for it, Git Bash on PATH, or Git for Windows where its installer puts it.
func gitBashAvailable() bool {
	if path := os.Getenv("CLAUDE_CODE_GIT_BASH_PATH"); path != "" {
		if _, err := os.Stat(path); err == nil {
			return true
		}
	}
	for _, name := range []string{"bash", "sh"} {
		if _, err := exec.LookPath(name); err == nil {
			return true
		}
	}
	for _, env := range []string{"ProgramFiles", "ProgramW6432", "LOCALAPPDATA"} {
		base := os.Getenv(env)
		if base == "" {
			continue
		}
		for _, rel := range []string{`Git\bin\bash.exe`, `Programs\Git\bin\bash.exe`} {
			if _, err := os.Stat(filepath.Join(base, rel)); err == nil {
				return true
			}
		}
	}
	return false
}

// Verb is how a tool step reads in the conversation: "ran ls", "edited main.go". The Mac's
// RemoteAccess.verb, so the shared web app shows the same words from either.
func Verb(tool string) string {
	switch tool {
	case "Bash", "shell":
		return "ran"
	case "Read":
		return "read"
	case "Write", "Edit", "MultiEdit", "edit":
		return "edited"
	case "WebFetch", "WebSearch":
		return "looked up"
	case "Grep", "Glob":
		return "searched"
	}
	if strings.HasPrefix(tool, "mcp__") {
		return "used"
	}
	return strings.ToLower(tool)
}

func clip(s string, n int) string {
	if runes := []rune(s); len(runes) > n {
		return string(runes[:n-1]) + "…"
	}
	return s
}
