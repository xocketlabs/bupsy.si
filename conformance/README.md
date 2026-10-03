# Conformance

One set of cases that **every** implementation of the core must pass.

bupsy will have more than one. `bupsy-run` is Go (decision #10), and a cross-platform core
would be too. The moment there are two, they drift — and they drift silently, in the places where
a comment explains why something is subtle. These cases turn that from invisible into a red build.

## The shape

Each case is a directory with an input and the exact canonical output expected from it:

```
cases/<name>/
  case.json        what kind of case, and any options
  input.ndjson     engine output, verbatim from a real run where possible
  expected.json    the canonical events, in order
```

A conforming implementation reads `input.ndjson`, normalises it, and produces `expected.json`.
No approximation: ordering, field names and values all match.

Run the Swift implementation against them with:

```bash
# Swift core (the macOS app)
swift test --package-path Packages/BupsyKit --filter Conformance

# Go core (headless, cross-platform)
cd Tools/bupsy-run && go test ./internal/conformance/ -v
```

Both read these same files from the repository rather than from a copy, because a copy drifts —
which is the exact failure this directory exists to catch.

## Why these cases exist

They are not a sample of happy paths. Each one pins a decision that was made deliberately and
would be easy to get wrong a second time:

- **`claude-session`** — a full run, start to finish. Proves the ordinary shape, and carries the
  undocumented `rate_limit_event` (the user's own subscription headroom — every field optional,
  because an undocumented shape can change without notice) plus a trailing unmodelled line, which
  must surface as `unknown` rather than be dropped. A schema change has to be visible.
- **`codex-session`** — a thread/turn/item stream that shares no structure with Claude's. This is
  what proves the canonical event type is not quietly Claude-shaped.
- **`codex-no-model-access`** — a turn that fails three different ways in one stream, including a
  JSON API error nested inside a string field. Captured verbatim from a real account.
- **`objective-outcomes`** — the asymmetry that matters most. `NEEDS_YOU:` and `OBJECTIVE_ACTED:`
  match anywhere; `OBJECTIVE_MET` must start a line. Lenient about escalation, strict about
  reassurance — a false "all is well" is the expensive direction. One row is captured verbatim: a
  model told to lead with a marker wrote `I'll check the drafts folder.NEEDS_YOU: …`.
- **`cron-expressions`** — `*/n` is **rejected**, not approximated. Every general-purpose cron
  library accepts it, so a port built on one silently accepts schedules this core refuses.
- **`claude-command`**, **`codex-command`** — the argv each engine is invoked with. Added because a
  wrong flag fails *before* a single event exists, so no stream case can see it. The two
  implementations had already drifted here (`--model` against `-m`, MCP paths forwarded to an
  engine with no such flag) within an hour of the second one being written.
- **`approval-gate`** — the gate's fail-closed behaviour. A `PreToolUse` hook that reaches its own
  timeout does **not** block, so the script must answer before the harness gives up; an
  implementation that closes that 30s gap converts a fail-closed gate into a fail-open one with no
  visible change until the night it matters. Asserted as constants *and* by generating the script
  with a zero-second wait and actually running it.
- **`codex-stderr`** — what diagnostic lines mean, and mostly what they do **not**. Three of its
  four lines must produce nothing. Added after the shipping core was found to be reporting
  `Reading additional input from stdin...` as a fatal protocol error on every single Codex run —
  see docs/01-spikes.md spike 6.

## Case kinds

Each `case.json` names a `kind`, and every implementation needs a runner for each. A runner that
meets an unknown kind must **fail**, not skip: a case nobody runs is worse than no case at all.

| kind | input | pins |
|---|---|---|
| `stream` | `input.ndjson` | stdout lines → canonical events |
| `stderr` | lines in `expected.json` | stderr lines → events, usually none |
| `command` | requests in `expected.json` | a run request → the exact argv |
| `objective` | replies in `expected.json` | an agent's reply → an outcome |
| `cron` | expressions in `expected.json` | what schedules are accepted and refused |
| `gate` | assertions in `expected.json` | the approval gate's timing and its unanswered decision |

A case compares only the fields it names, so an implementation may carry extra detail — a raw line
kept for the audit log, a cost figure one engine reports and the other does not — without every
case having to enumerate it. The flip side is that a case guards only what it names, which is why
every non-obvious row carries a `why`. Runners print it on failure, because the fastest way to
"fix" a drift failure is to change the expectation, and that is usually exactly the wrong move.

## Adding a case

Add one whenever a bug is found that a second implementation could repeat. A fixture captured
from a real run is worth more than one written by hand — sanitise it (no session ids, paths or
tool inventories from a real machine) and drop it in.
