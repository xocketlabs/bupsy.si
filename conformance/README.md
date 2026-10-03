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
swift test --package-path Packages/BupsyKit --filter Conformance
```

## Why these cases exist

They are not a sample of happy paths. Each one pins a decision that was made deliberately and
would be easy to get wrong a second time:

- **`claude-session`** — a full run. Proves the ordinary shape.
- **`claude-rate-limit`** — the undocumented `rate_limit_event` carrying the user's own
  subscription headroom. Every field optional: an undocumented shape can change without notice.
- **`claude-unknown-event`** — an unmodelled line must surface as `unknown`, never be dropped.
  A schema change has to be visible, not silent.
- **`codex-session`** — a thread/turn/item stream that shares no structure with Claude's. This is
  what proves the canonical event type is not quietly Claude-shaped.
- **`codex-buried-marker`** — captured verbatim: a model told to lead with a marker wrote
  `I'll check the drafts folder.NEEDS_YOU: …`. Escalation markers are matched **anywhere**,
  because missing one buries a question only a person can answer.
- **`objective-outcomes`** — the asymmetry that matters most. `NEEDS_YOU:` and
  `OBJECTIVE_ACTED:` match anywhere; `OBJECTIVE_MET` must start a line. Lenient about
  escalation, strict about reassurance — a false "all is well" is the expensive direction.
- **`cron-expressions`** — `*/n` is **rejected**, not approximated. Every general-purpose cron
  library accepts it, so a port built on one silently accepts schedules this core refuses.

## Adding a case

Add one whenever a bug is found that a second implementation could repeat. A fixture captured
from a real run is worth more than one written by hand — sanitise it (no session ids, paths or
tool inventories from a real machine) and drop it in.
