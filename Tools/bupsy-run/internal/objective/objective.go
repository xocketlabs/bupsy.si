// Package objective reads an agent's reply to a standing-goal check into an outcome.
package objective

import "strings"

// Markers the bot is asked to use. Distinctive enough not to appear by accident in ordinary prose.
const (
	markerMet      = "OBJECTIVE_MET"
	markerActed    = "OBJECTIVE_ACTED:"
	markerNeedsYou = "NEEDS_YOU:"
)

// Outcome is what a check concluded.
type Outcome string

const (
	// Met means nothing to do: the cheap, common case on a healthy objective.
	Met Outcome = "met"
	// Acted means the bot did something to move toward the goal.
	Acted Outcome = "acted"
	// NeedsYou means a person has to decide. Surfaces in the attention inbox.
	NeedsYou Outcome = "needsYou"
	// Unclear means the run finished but said nothing we could read.
	//
	// Deliberately not folded into Met. Treating an unreadable answer as success would quietly
	// report a goal as handled when nobody knows whether it was, which is the single most
	// damaging thing this feature could do.
	Unclear Outcome = "unclear"
	Failed  Outcome = "failed"
)

// NeedsAttention reports whether the outcome should pull a human in.
func (o Outcome) NeedsAttention() bool {
	return o == NeedsYou || o == Failed || o == Unclear
}

// Read turns a reply into an outcome and its one-line detail.
//
// Matching is deliberately asymmetric, and this is the most important decision in the package.
// Observed against the real binary: a model told to lead with a marker sometimes writes
// `I'll check the drafts folder.NEEDS_YOU: ...` — correct marker, wrong position. Requiring every
// marker to start a line would have silently dropped that escalation.
//
// So:
//   - NEEDS_YOU: and OBJECTIVE_ACTED: are found anywhere. They carry a colon and a payload, so a
//     false positive is unlikely, and missing one means burying a question only a person can
//     answer.
//   - OBJECTIVE_MET must start a line. It is the "all is well" answer, so a false positive is the
//     expensive direction — a bot discussing the marker in prose must never read as success.
//
// Lenient about escalation, strict about reassurance. Anything unreadable becomes Unclear, never
// Met.
func Read(reply string) (Outcome, string) {
	// Most urgent first: a reply that both acted and hit a decision must surface the decision.
	if question, found := payload(markerNeedsYou, reply); found {
		if question == "" {
			question = "A decision is needed."
		}
		return NeedsYou, question
	}
	if summary, found := payload(markerActed, reply); found {
		if summary == "" {
			summary = "Took action."
		}
		return Acted, summary
	}

	for _, raw := range strings.Split(reply, "\n") {
		if strings.HasPrefix(strings.TrimSpace(raw), markerMet) {
			return Met, ""
		}
	}

	trimmed := strings.TrimSpace(reply)
	if trimmed == "" {
		trimmed = "The bot replied with nothing."
	}
	return Unclear, trimmed
}

// payload returns the text following a marker, up to the end of its line, wherever the marker
// appears.
func payload(marker, reply string) (string, bool) {
	index := strings.Index(reply, marker)
	if index < 0 {
		return "", false
	}
	rest := reply[index+len(marker):]
	if end := strings.IndexByte(rest, '\n'); end >= 0 {
		rest = rest[:end]
	}
	return strings.TrimSpace(rest), true
}

// Learnings pulls out anything the bot asked to remember, to append to the objective's notes.
func Learnings(reply string) []string {
	var out []string
	for _, raw := range strings.Split(reply, "\n") {
		trimmed := strings.TrimSpace(raw)
		if !strings.HasPrefix(trimmed, "NOTE:") {
			continue
		}
		note := strings.TrimSpace(strings.TrimPrefix(trimmed, "NOTE:"))
		if note != "" {
			out = append(out, note)
		}
	}
	return out
}
