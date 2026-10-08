package store

import (
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
)

// Record is one line of a bot's log.
//
// A flat struct with a type tag rather than an interface, for the same reason engine.Event is
// one: it is serialised line by line and read back by tools that are not this program.
type Record struct {
	Type RecordType `json:"type"`
	At   time.Time  `json:"at"`

	// Entry is the visible line, for RecordEntry.
	Entry *Entry `json:"entry,omitempty"`
	// Ref names what a later record is about: an approval, a tool call, a question.
	Ref string `json:"ref,omitempty"`
	// Decision is "allowed", "denied" or "expired", for RecordDecided and RecordGate.
	Decision string `json:"decision,omitempty"`
	// Rule is why the policy allowed a call without asking, for RecordGate.
	Rule string `json:"rule,omitempty"`
	Tool string `json:"tool,omitempty"`
	// Text is a question's answer, for RecordAnswered.
	Text string `json:"text,omitempty"`

	// Run ties engine events and run markers to one run of the engine.
	Run    string        `json:"run,omitempty"`
	Status string        `json:"status,omitempty"`
	Event  *engine.Event `json:"event,omitempty"`
}

// RecordType says what a Record is.
type RecordType string

const (
	// RecordEntry is a line the person sees: their message, the bot's reply, a tool step, a card.
	RecordEntry RecordType = "entry"
	// RecordDecided settles an approval card: allowed, denied, or expired unanswered.
	RecordDecided RecordType = "decided"
	// RecordToolFailed marks a tool step as having failed, once its result arrives.
	RecordToolFailed RecordType = "toolFailed"
	// RecordAnswered records the answer to a question card.
	RecordAnswered RecordType = "answered"
	// RecordGate is the audit line for a call the policy allowed without asking anyone. Every
	// call passes the gate, so the log has no holes even on a bot trusted to act alone.
	RecordGate RecordType = "gate"
	// RecordRun marks a run starting and ending, with how it ended.
	RecordRun RecordType = "run"
	// RecordEngine is one canonical engine event, kept whole: the full record of what the bot
	// did, including what the conversation view leaves out (thinking, usage, unknown lines).
	RecordEngine RecordType = "engine"
)

// Run statuses, in RecordRun.Status.
const (
	RunStarted  = "started"
	RunFinished = "finished"
	RunFailed   = "failed"
	RunStopped  = "stopped"
)

// Decisions on an approval.
const (
	Allowed = "allowed"
	Denied  = "denied"
	Expired = "expired"
)

// Entry kinds, as the web app reads them.
const (
	KindYou      = "you"
	KindBot      = "bot"
	KindFrom     = "from"
	KindTool     = "tool"
	KindApproval = "approval"
	KindQuestion = "question"
	KindNote     = "note"
	KindFailure  = "failure"
)

// Entry is one visible line of a conversation.
type Entry struct {
	ID       string    `json:"id"`
	Kind     string    `json:"kind"`
	At       time.Time `json:"at"`
	Text     string    `json:"text,omitempty"`
	Author   string    `json:"author,omitempty"`
	Tool     *Tool     `json:"tool,omitempty"`
	Approval *Approval `json:"approval,omitempty"`
	Question *Question `json:"question,omitempty"`
}

// Tool is a step the bot took.
type Tool struct {
	CallID string `json:"callID,omitempty"`
	Name   string `json:"name"`
	Verb   string `json:"verb"`
	Target string `json:"target"`
	Failed bool   `json:"failed,omitempty"`
}

// Approval is a tool call waiting for the person, or one they have answered.
type Approval struct {
	ID      string `json:"id"`
	Tool    string `json:"tool"`
	Summary string `json:"summary"`
	Reason  string `json:"reason"`
	// Decided is empty while it waits.
	Decided string `json:"decided,omitempty"`
}

// Question is a multiple-choice question from the bot.
type Question struct {
	ID       string   `json:"id"`
	Question string   `json:"question"`
	Options  []string `json:"options"`
	Answer   string   `json:"answer,omitempty"`
}

// Thread is a conversation as shown: the log folded into its current state.
//
// Folding is the only way a Thread is built, whether from the whole log at load or one record at
// a time as a run goes. One code path for both means what a person sees live is exactly what they
// see after a restart.
type Thread struct {
	Entries []Entry
	// LastRun is how the most recent run ended, or RunStarted if it never recorded an end —
	// which, read back from disk, means the program stopped while it ran.
	LastRun string

	approvals map[string]int
	tools     map[string]int
	questions map[string]int
}

// Fold builds a thread from records.
func Fold(records []Record) *Thread {
	thread := &Thread{}
	for _, record := range records {
		thread.Apply(record)
	}
	return thread
}

// Apply folds one more record in.
func (t *Thread) Apply(record Record) {
	if t.approvals == nil {
		t.approvals, t.tools, t.questions = map[string]int{}, map[string]int{}, map[string]int{}
	}
	switch record.Type {
	case RecordEntry:
		if record.Entry == nil {
			return
		}
		entry := cloneEntry(*record.Entry)
		index := len(t.Entries)
		t.Entries = append(t.Entries, entry)
		switch {
		case entry.Approval != nil:
			t.approvals[entry.Approval.ID] = index
		case entry.Tool != nil && entry.Tool.CallID != "":
			t.tools[entry.Tool.CallID] = index
		case entry.Question != nil:
			t.questions[entry.Question.ID] = index
		}
	case RecordDecided:
		// First decision wins. A late "expired" after an answer, or a second answer from another
		// device, never rewrites what actually happened.
		if index, ok := t.approvals[record.Ref]; ok && t.Entries[index].Approval.Decided == "" {
			t.Entries[index].Approval.Decided = record.Decision
		}
	case RecordToolFailed:
		if index, ok := t.tools[record.Ref]; ok {
			t.Entries[index].Tool.Failed = true
		}
	case RecordAnswered:
		if index, ok := t.questions[record.Ref]; ok && t.Entries[index].Question.Answer == "" {
			t.Entries[index].Question.Answer = record.Text
		}
	case RecordRun:
		t.LastRun = record.Status
	}
}

// Approval returns an approval card by id.
func (t *Thread) Approval(id string) (Approval, bool) {
	if index, ok := t.approvals[id]; ok {
		return *t.Entries[index].Approval, true
	}
	return Approval{}, false
}

// Undecided lists the ids of approvals still waiting, oldest first.
func (t *Thread) Undecided() []string {
	var ids []string
	for _, entry := range t.Entries {
		if entry.Approval != nil && entry.Approval.Decided == "" {
			ids = append(ids, entry.Approval.ID)
		}
	}
	return ids
}

// OpenQuestion reports whether a question is still unanswered.
func (t *Thread) OpenQuestion(id string) bool {
	index, ok := t.questions[id]
	return ok && t.Entries[index].Question.Answer == ""
}

// Clone copies the thread, so a reader can hold it while runs keep appending.
func (t *Thread) Clone() *Thread {
	out := &Thread{LastRun: t.LastRun}
	for _, entry := range t.Entries {
		out.Apply(Record{Type: RecordEntry, Entry: &entry})
	}
	return out
}

func cloneEntry(entry Entry) Entry {
	if entry.Tool != nil {
		tool := *entry.Tool
		entry.Tool = &tool
	}
	if entry.Approval != nil {
		approval := *entry.Approval
		entry.Approval = &approval
	}
	if entry.Question != nil {
		question := *entry.Question
		question.Options = append([]string(nil), question.Options...)
		entry.Question = &question
	}
	return entry
}
