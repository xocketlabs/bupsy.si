package desktop

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/runner"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/store"
)

// route answers a paired browser. The routes, shapes and messages are the Mac's
// (RemoteAccess.route), so the page cannot tell which it is talking to.
func (s *Server) route(w http.ResponseWriter, r *http.Request) {
	// "/api/bots/<id>/approvals/<approval>" becomes ["bots", "<id>", "approvals", "<approval>"].
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/"), "/"), "/")
	get, post := r.Method == http.MethodGet, r.Method == http.MethodPost

	if get && len(parts) == 1 && parts[0] == "session" {
		writeJSON(w, map[string]any{"mac": s.Machine}, http.StatusOK)
		return
	}
	if get && len(parts) == 1 && parts[0] == "bots" {
		bots := ordered(s.Store.Bots())
		list := make([]any, 0, len(bots))
		waiting := 0
		for _, bot := range bots {
			state := s.Runner.State(bot)
			if state.NeedsYou {
				waiting++
			}
			list = append(list, botJSON(bot, state))
		}
		writeJSON(w, map[string]any{"bots": list, "waiting": waiting}, http.StatusOK)
		return
	}
	if len(parts) < 3 || parts[0] != "bots" {
		writeError(w, "Not found", http.StatusNotFound)
		return
	}
	bot, ok := s.Store.Bot(parts[1])
	if !ok {
		writeError(w, "Not found", http.StatusNotFound)
		return
	}
	action := parts[2:]

	switch {
	case get && len(action) == 1 && action[0] == "messages":
		thread, err := s.Runner.Thread(bot.ID)
		if err != nil {
			writeError(w, "Not found", http.StatusNotFound)
			return
		}
		// Shown, so read. The sidebar's unread dot clears the way it does on the Mac when the
		// conversation is open.
		s.Runner.MarkRead(bot.ID)
		bot, _ = s.Store.Bot(bot.ID)
		writeJSON(w, map[string]any{"bot": botJSON(bot, s.Runner.State(bot)), "entries": entriesJSON(thread)}, http.StatusOK)

	case post && len(action) == 1 && action[0] == "messages":
		text, _ := readJSON(w, r)["text"].(string)
		err := s.Runner.Send(bot.ID, text)
		switch {
		case errors.Is(err, runner.ErrEmpty):
			writeError(w, "Write something first.", http.StatusBadRequest)
		case err != nil:
			writeError(w, err.Error(), http.StatusServiceUnavailable)
		default:
			writeJSON(w, map[string]any{"ok": true}, http.StatusOK)
		}

	case post && len(action) == 2 && action[0] == "approvals":
		allow, ok := readJSON(w, r)["allow"].(bool)
		if !ok {
			writeError(w, "Allow or deny?", http.StatusBadRequest)
			return
		}
		err := s.Runner.Decide(bot.ID, action[1], allow)
		switch {
		case errors.Is(err, runner.ErrAnswered):
			writeError(w, "That request was already answered.", http.StatusConflict)
		case err != nil:
			writeError(w, "That answer couldn't be passed on: "+err.Error(), http.StatusInternalServerError)
		default:
			writeJSON(w, map[string]any{"ok": true}, http.StatusOK)
		}

	case post && len(action) == 2 && action[0] == "questions":
		answer, ok := readJSON(w, r)["answer"].(string)
		if !ok {
			writeError(w, "No answer given.", http.StatusBadRequest)
			return
		}
		if err := s.Runner.Answer(bot.ID, action[1], answer); err != nil {
			writeError(w, "That question was already answered.", http.StatusConflict)
			return
		}
		writeJSON(w, map[string]any{"ok": true}, http.StatusOK)

	case post && len(action) == 1 && action[0] == "stop":
		s.Runner.Stop(bot.ID)
		writeJSON(w, map[string]any{"ok": true}, http.StatusOK)

	default:
		writeError(w, "Not found", http.StatusNotFound)
	}
}

// ordered is the sidebar's order: bots in no section first, then each section in turn, in the
// order sections first appear. (The Mac also has pinned bots; the desktop has no pinning yet.)
func ordered(bots []store.Bot) []store.Bot {
	out := make([]store.Bot, 0, len(bots))
	var sections []string
	seen := map[string]bool{}
	for _, bot := range bots {
		if bot.Section == "" {
			out = append(out, bot)
		} else if !seen[bot.Section] {
			seen[bot.Section] = true
			sections = append(sections, bot.Section)
		}
	}
	for _, section := range sections {
		for _, bot := range bots {
			if bot.Section == section {
				out = append(out, bot)
			}
		}
	}
	return out
}

// orNull is the JSON the Mac sends for an absent string: null, not "".
func orNull(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func botJSON(bot store.Bot, state runner.State) map[string]any {
	return map[string]any{
		"id":       bot.ID,
		"name":     bot.Name,
		"role":     orNull(bot.Role),
		"section":  orNull(bot.Section),
		"colour":   bot.Colour,
		"mood":     state.Mood,
		"running":  state.Running,
		"needsYou": state.NeedsYou,
		"unread":   state.Unread,
		"preview":  orNull(state.Preview),
	}
}

// entriesJSON is the latest visible entries, oldest first: the Mac's window of 160 entries, of
// which at most the last 80 are sent.
func entriesJSON(thread *store.Thread) []any {
	entries := thread.Entries
	if len(entries) > 160 {
		entries = entries[len(entries)-160:]
	}
	out := make([]any, 0, len(entries))
	for _, entry := range entries {
		item := map[string]any{"id": entry.ID, "kind": entry.Kind, "at": entry.At.UTC().Format(time.RFC3339)}
		switch entry.Kind {
		case store.KindYou, store.KindBot, store.KindNote, store.KindFailure:
			item["text"] = entry.Text
		case store.KindFrom:
			item["author"] = entry.Author
			item["text"] = entry.Text
		case store.KindTool:
			if entry.Tool == nil {
				continue
			}
			item["tool"] = map[string]any{"verb": entry.Tool.Verb, "target": entry.Tool.Target, "failed": entry.Tool.Failed}
		case store.KindApproval:
			if entry.Approval == nil {
				continue
			}
			a := entry.Approval
			item["approval"] = map[string]any{
				"id": a.ID, "tool": a.Tool, "summary": a.Summary, "reason": a.Reason, "decided": orNull(a.Decided),
			}
		case store.KindQuestion:
			if entry.Question == nil {
				continue
			}
			q := entry.Question
			options := q.Options
			if options == nil {
				options = []string{}
			}
			item["question"] = map[string]any{"id": q.ID, "question": q.Question, "options": options, "answer": orNull(q.Answer)}
		default:
			continue
		}
		out = append(out, item)
	}
	if len(out) > 80 {
		out = out[len(out)-80:]
	}
	return out
}
