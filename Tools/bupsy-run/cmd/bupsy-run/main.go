// Command bupsy-run drives one agent CLI and writes canonical NDJSON events to stdout.
//
// This is the seam the headless core grows along. The macOS app has its own Swift implementation
// of the same mappings, and /conformance holds the cases both must pass — so this is not a second
// product, it is the same core in a language that runs where Swift's SQLite layer does not. See
// docs/03-decisions.md #28.
//
// The credential rule is the same here as everywhere: this process spawns the vendor binary and
// never holds, reads or forwards a vendor credential. Sign-in is the user's own, in their own
// CLI, in files this program never opens.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/engine"
	"github.com/xocketlabs/bupsy.si/tools/bupsy-run/internal/host"
)

func main() {
	engineID := flag.String("engine", "claude", "engine to drive: claude or codex")
	prompt := flag.String("prompt", "", "the prompt to run (required)")
	dir := flag.String("dir", "", "working directory for the run")
	model := flag.String("model", "", "model to request; empty means the CLI's own default")
	resume := flag.String("resume", "", "conversation to continue")
	autonomy := flag.String("autonomy", engine.AutonomyAsk,
		"trust level: "+strings.Join(engine.Autonomies, ", "))
	binary := flag.String("binary", "", "path to the engine binary, if it is not on PATH")
	flag.Parse()

	if *prompt == "" {
		fmt.Fprintln(os.Stderr, "bupsy-run: --prompt is required")
		flag.Usage()
		os.Exit(2)
	}

	adapter, err := adapterFor(*engineID, *binary)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bupsy-run:", err)
		os.Exit(2)
	}
	if err := checkAutonomy(*engineID, *autonomy); err != nil {
		fmt.Fprintln(os.Stderr, "bupsy-run:", err)
		os.Exit(2)
	}

	// Ctrl-C and SIGTERM cancel the context, which kills the child. Without this a cancelled run
	// would leave an engine process holding the user's quota open with nobody reading its output.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	req := engine.Request{
		Prompt:     *prompt,
		WorkingDir: *dir,
		Model:      *model,
		Resume:     *resume,
		Autonomy:   *autonomy,
	}

	name, args := adapter.Command(req)
	path, err := host.Resolve(name)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bupsy-run:", err)
		os.Exit(1)
	}

	// Encoding straight to stdout, one event per line, flushed as it goes: a caller tailing this
	// is watching a run happen, so buffering would turn a live transcript into a long silence
	// followed by everything at once.
	out := json.NewEncoder(os.Stdout)
	failed := false
	emit := func(event engine.Event) {
		if event.Kind == engine.KindFailed {
			failed = true
		}
		if err := out.Encode(event); err != nil {
			// A broken pipe means our reader went away; there is nobody left to tell.
			os.Exit(1)
		}
	}

	if err := host.RunResolved(ctx, path, args, adapter, req, emit); err != nil {
		emit(engine.Event{Kind: engine.KindFailed, Message: err.Error()})
		os.Exit(1)
	}
	// A run whose stream reported a failure exits non-zero, so a shell or a scheduler sees it as
	// failed without having to parse the transcript.
	if failed {
		os.Exit(1)
	}
}

func adapterFor(id, binary string) (engine.Adapter, error) {
	switch id {
	case "claude":
		return engine.Claude{Binary: binary}, nil
	case "codex":
		return engine.Codex{Binary: binary}, nil
	default:
		return nil, errors.New("unknown engine " + id + " (want claude or codex)")
	}
}

// checkAutonomy decides whether this run can actually be held to the trust level asked for, and
// refuses it when it cannot. Failing closed is the point: a run that starts is a run the person
// believes is gated.
//
// Codex enforces every level itself, through the sandbox chosen before it starts, so any level on
// the ladder is fine. Claude is different: below auto, its only enforcement is the approval hook,
// and that hook waits for a person to answer in the app (internal/gate). bupsy-run has no app and
// nobody to answer, so installing the hook would hold every tool call for minutes and then deny it,
// and NOT installing it — what this command used to do — ran Claude with whatever the user's own
// settings allow, ignoring the level entirely. Neither is what was asked for, so it says so.
func checkAutonomy(engineID, autonomy string) error {
	if err := engine.CheckAutonomy(autonomy); err != nil {
		return err
	}
	if engineID == "claude" && autonomy != engine.AutonomyAuto {
		return fmt.Errorf("claude enforces --autonomy %s through an approval hook that waits for "+
			"a person in the bupsy app, and bupsy-run has no one to ask. Refusing rather than "+
			"running ungated: pass --autonomy auto to run without approvals knowingly, or use "+
			"--engine codex, whose sandbox enforces %s on its own", autonomy, autonomy)
	}
	return nil
}
