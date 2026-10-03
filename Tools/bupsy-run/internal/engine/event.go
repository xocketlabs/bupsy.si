// Package engine drives agent CLIs and turns their output into one canonical event stream.
//
// This mirrors BupsyKit's Swift implementation on purpose. The two must agree, and
// conformance/cases is what holds them to it: the same inputs must produce the same events from
// either language. Where this file looks like a translation rather than idiomatic Go, that is
// why — the shared definition wins over local taste.
package engine

// Kind identifies what an Event is. The string values are the ones conformance/cases uses, so
// they are part of the shared contract rather than an internal detail.
type Kind string

const (
	KindStarted    Kind = "started"
	KindText       Kind = "text"
	KindThinking   Kind = "thinking"
	KindToolCall   Kind = "toolCall"
	KindToolResult Kind = "toolResult"
	KindApproval   Kind = "approvalRequired"
	KindUsage      Kind = "usage"
	KindRateLimit  Kind = "rateLimit"
	KindConnectors Kind = "connectors"
	KindDone       Kind = "done"
	KindFailed     Kind = "failed"
	// KindUnknown is a line that parsed as JSON but whose shape we do not model. It is never
	// dropped: a schema change has to be visible in the transcript rather than silently
	// swallowed, which is the same rule the Swift side follows.
	KindUnknown Kind = "unknown"
)

// Event is one thing an engine said, in the canonical shape.
//
// A single struct with optional fields rather than an interface: these are serialised to NDJSON
// and read back by tools in other languages, so a flat shape that maps cleanly to JSON is worth
// more than Go's usual preference for small interfaces.
type Event struct {
	Kind Kind `json:"type"`

	ConversationID string `json:"conversationID,omitempty"`
	Text           string `json:"text,omitempty"`

	Name      string `json:"name,omitempty"`
	Arguments string `json:"arguments,omitempty"`
	CallID    string `json:"callID,omitempty"`
	Content   string `json:"content,omitempty"`
	// IsError is a pointer so a successful tool result still says so. With a plain bool the
	// field would vanish when false, and "the tool did not fail" would be indistinguishable
	// from "nobody said" in the canonical stream.
	IsError *bool `json:"isError,omitempty"`

	InputTokens  *int     `json:"inputTokens,omitempty"`
	OutputTokens *int     `json:"outputTokens,omitempty"`
	CostUSD      *float64 `json:"costUSD,omitempty"`

	// Status and Windows carry the engine's report of the user's own subscription headroom.
	// Undocumented upstream, so every field is optional and a missing one degrades the reading
	// rather than failing the run.
	Status  string             `json:"status,omitempty"`
	Windows map[string]float64 `json:"windows,omitempty"`

	Connectors []ConnectorState `json:"connectors,omitempty"`

	FailureKind string `json:"failureKind,omitempty"`
	Message     string `json:"message,omitempty"`

	// Raw is the original line, kept for KindUnknown so the audit log holds what we could not read.
	Raw string `json:"raw,omitempty"`
}

// ConnectorState is an MCP server as the engine found it, not as it was configured. A server can
// be set up correctly and still fail to start, and the user should see that.
type ConnectorState struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

// Adapter turns one engine's native output into canonical events.
type Adapter interface {
	// ID is the engine's name: "claude", "codex".
	ID() string
	// Command is the binary and arguments for a run.
	Command(req Request) (string, []string)
	// Normalise converts one line of stdout. It may return zero, one or several events, and must
	// never discard a line it cannot read — that becomes KindUnknown.
	Normalise(line string) []Event
	// NormaliseStderr converts one line of stderr. Most lines are diagnostics and produce nothing.
	NormaliseStderr(line string) []Event
	// Exit converts the process's exit status. Not every engine has something to say here: one
	// that already reported the failure in its stream returns nothing, because showing the user
	// the same problem twice is its own bug.
	Exit(code int) []Event
}

// Request is one run of an engine.
type Request struct {
	Prompt     string
	WorkingDir string
	Resume     string
	Model      string
	// Autonomy is the trust level, which engines enforce differently: Claude through a blocking
	// hook, Codex through a sandbox policy chosen before the run.
	Autonomy   string
	MCPConfigs []string
	// GateSettings is the settings file installing the approval hook, for engines that have one.
	GateSettings string
}
