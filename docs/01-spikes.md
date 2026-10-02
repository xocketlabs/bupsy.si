# M0 spikes — run before any product code

Six assumptions hold up the plan. Spikes 1 and 2 are the two halves of the premise: if 1 fails the
product does not work, and if 2 fails we are just another chat wrapper with no answer to Dots.

Budget: 2–3 days. Cost: a boat plan (~$20, 7-day trial) and an Apple Developer account ($99/yr,
needed from M1 anyway). Record every result in the table at the bottom.

---

## Spike 1 — Does a subscription survive a VM snapshot? **(gating)**

The claim: a user signs their own Claude subscription into their own VM, and it survives stop/resume
so a routine still runs days later without re-login.

```bash
boat new --no-env --name spike1
boat ssh spike1

# inside the VM — the user's own flow; we only render it
claude
# /login → complete in browser → /exit
claude -p "Reply with exactly: HELLO FROM VM" --output-format stream-json --verbose
exit

boat stop spike1          # snapshot, pause billing
boat resume spike1
boat ssh spike1 -- claude -p "Reply with exactly: STILL SIGNED IN"
```

Then Codex, and check credential-store behaviour across snapshots:

```bash
boat ssh spike1 -- codex login --device-auth
boat ssh spike1 -- codex login status
# set cli_auth_credentials_store = "file" in ~/.codex/config.toml, then:
boat stop spike1 && boat resume spike1
boat ssh spike1 -- codex login status
```

**Also check the local path**, which M1 depends on: `claude -p` on this Mac, spawned from a
non-sandboxed process, using the Mac's own `~/.claude`.

**Pass:** second prompt succeeds, no re-login, both hosts.
**Fail:** check whether `~/.claude` sits on a persisted path; if it genuinely cannot survive, the
cloud half is dead as designed → local-only product, or stop.

**Longevity:** re-run on day 3 and day 7. *How long a sign-in stays valid decides whether weekly
routines can be trusted at all* and sets the reconnect-nudge cadence. Do not skip this.

---

## Spike 2 — Does VM-side cron fire with the Mac closed? **(the differentiator)**

The claim behind §4 of the plan: routines run in the user's VM, so always-on does not depend on the
Mac being awake.

```bash
boat ssh spike1
cat > ~/run-probe.sh <<'EOS'
#!/bin/bash
mkdir -p ~/.bupsy/events
claude -p "Reply with exactly: CRON RAN AT $(date -Is)" --output-format stream-json --verbose \
  >> ~/.bupsy/events/probe.ndjson 2>&1
EOS
chmod +x ~/run-probe.sh
( crontab -l 2>/dev/null; echo "*/5 * * * * /home/user/run-probe.sh" ) | crontab -
crontab -l
exit
```

Now **close the Mac lid for 20 minutes.** Reopen and:

```bash
boat ssh spike1 -- wc -l '~/.bupsy/events/probe.ndjson'
boat ssh spike1 -- tail -3 '~/.bupsy/events/probe.ndjson'
```

Answer four things:

1. Did cron fire with no client connected? (Expect yes — it is a real VM.)
2. **Does a *stopped* VM wake for its own cron, or does it stay asleep?** Almost certainly asleep —
   a snapshot is not running. If so, the always-on design needs one of:
   - keep the VM running on a `small` size between routine windows (costs more, simplest), or
   - a `systemd-timer`-plus-sleep pattern where the VM self-manages, or
   - accept that routines need the VM awake and have the Mac wake it when it can — which
     **reintroduces the sleeping-Mac problem** and would be the single biggest blow to the plan.
   **Price the always-running `small` option here**, because it is the honest fallback.
3. Is cron the right mechanism, or should `bupsy-run` be a long-lived `systemd` service holding its
   own schedule? (A service can wake-on-nothing but survives better and gives us one place to log.)
4. Is `crontab` even writable in a boat sandbox, and does it survive snapshot/resume?

**This spike decides whether the Dots half is real.** Do not move past it on an assumption.

---

## Spike 3 — Parse a real stream from Swift

Foundation for every adapter. Two parts: confirm the exact flags, then prove the Swift plumbing.

**The docs redirect a lot, so do not trust remembered flags — enumerate them:**

```bash
claude --help | tee docs/samples/claude-flags.txt
codex --help  | tee docs/samples/codex-flags.txt
```

Confirm specifically: `-p`, `--output-format stream-json`, `--verbose`, `--resume`,
`--permission-mode`, `--mcp-config`, `--allowed-tools`, `--append-system-prompt`, and whether any
partial-message/token-level streaming flag exists. Capture real streams as normaliser fixtures:

```bash
mkdir -p docs/samples
claude -p "List the files here, then summarise them" --output-format stream-json --verbose \
  > docs/samples/claude-stream.ndjson
codex exec "List the files here" > docs/samples/codex-stream.txt 2>&1
```

Then the Swift side — spawn, stream, parse line-delimited JSON without buffering to EOF:

```swift
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = ["claude", "-p", "say hi", "--output-format", "stream-json", "--verbose"]
let out = Pipe(); p.standardOutput = out
try p.run()
for try await line in out.fileHandleForReading.bytes.lines {
    print(try JSONDecoder().decode(StreamEvent.self, from: Data(line.utf8)))
}
```

Verify: events arrive **incrementally** (not all at once on exit); the process is killable mid-run;
stderr is captured separately; a non-login shell still finds `claude` on `PATH` (**a GUI app's
`PATH` is not your terminal's** — expect to resolve the binary explicitly, and spike that).

Deliverable: `docs/samples/*.ndjson` committed as normaliser test fixtures.

### Spike 3 findings, in detail

Run it yourself with `make spike`.

**Passed.** `ClaudeAdapter` + `LocalHost` + `BinaryResolver` are built and tested against the real
binary. Three things worth carrying forward:

1. **`BinaryResolver` is load-bearing, exactly as suspected.** `claude` installs to
   `~/.local/bin`, which is on no default system path. A GUI app inheriting launchd's minimal
   environment would simply not find it. Resolution goes: absolute path → common install
   directories → the user's own login shell.

2. **🎁 `rate_limit_event` — an undocumented gift.** Every run begins with the engine reporting the
   user's own subscription utilisation:

   ```json
   {"type":"rate_limit_event","rate_limit_info":{
     "status":"allowed","rateLimitType":"five_hour","isUsingOverage":false,
     "unifiedWindows":{"five_hour":{"utilization":0.03,"resetsAt":1790955000},
                       "seven_day":{"utilization":0.01,"resetsAt":1791453600}}}}
   ```

   This is the limit-burn gauge PLAN.md deferred to M5, handed over for free and accurate rather
   than estimated from token counts. It is now modelled as `AgentEvent.rateLimit` and moved to M2.
   Being undocumented, every field is optional and a shape change degrades the gauge rather than
   breaking a run — there is a test for precisely that.

3. **⚠️ `total_cost_usd` is notional, and dangerous to show.** A two-token prompt reported
   **$0.36**, because cache creation dominates the figure. A subscription user paid none of it.
   Never label this "what you paid"; see the comment on `Usage.costUSD`.

**Still open on spike 3:** a full `claude --help` / `codex --help` sweep to pin the complete flag
set, and the same end-to-end run against a `CloudHost` once spike 1 provisions a VM.

---

## Spike 4 — What is each engine's real approval mechanism?

§6 of the plan assumes one approval card over per-engine mechanisms. That abstraction is only as
good as its worst engine.

**Claude Code** — confirm a `PreToolUse` hook can *block* and return a decision, and that it works
in `-p` mode on both hosts:

```bash
mkdir -p ~/.claude
cat > /tmp/gate.sh <<'EOS'
#!/bin/bash
echo "GATE HIT: $(cat)" >> /tmp/gate.log
# emit the documented deny/ask response shape and verify the agent honours it
EOS
chmod +x /tmp/gate.sh
# register the hook in settings, then:
claude -p "Run: rm -rf /tmp/should-not-happen" --output-format stream-json --verbose
cat /tmp/gate.log
```

Confirm: the hook receives tool name and arguments; it can deny; it can hold long enough for a
human (what is the timeout?); the agent continues sensibly after a denial.

**Codex and Grok** — find the equivalent. Read `--help` for approval/sandbox modes. If an engine
has no blocking mechanism, write that down plainly: that engine cannot be offered above `ask`, and
the UI must say so rather than imply a guarantee we cannot keep.

Also: for cloud runs, how does a gate in the VM reach the Mac? Confirm the shape — pending-file in
`~/.bupsy/pending/` plus polling is the simplest thing that works offline.

---

## Spike 5 — Latency and real cost

```bash
boat stop spike1
time boat resume spike1
time boat ssh spike1 -- claude -p "hi"          # snapshot → first token, 5 runs
```

Record min/median/max. **Target under 15s.** Then a real 30-minute agentic task, and:

```bash
curl -H "Authorization: Bearer $BOAT_API_KEY" https://api.boat.dev/v1/sandboxes/spike1/usage
```

Extrapolate a realistic month: 3 bots × 4 routines/day × 10 min ≈ 6 VM-hours. Compare against
boat's $20 → 2,000,000 VM-seconds (~555h at 1x). **Also price the always-running `small` fallback
from spike 2** — it is the number that decides whether always-on is affordable for users.

Note how much of the *subscription* limit that session burned; it drives the M5 limit-burn warnings
and is the figure most likely to surprise us.

---

## Spike 6 — UI dependencies actually exist

Cheap, but it decides §7. libraries.dev says Beam and Orb support SwiftUI; verify rather than trust:

- Find the actual SwiftUI package URLs; add via SPM to a throwaway Xcode project; render both.
- Check the macOS deployment target matches ours (14+) and the licence is MIT in the repo itself.
- Render boat's desktop URL in a `WKWebView` — does noVNC work in a web view, can it take input,
  what is the frame rate?
- Confirm an unsandboxed SwiftUI app with hardened runtime can still `Process`-spawn a Homebrew
  binary, and note which entitlements that needs.

---

## Results

| # | Spike | Result | Notes | Date |
|---|---|---|---|---|
| 1 | Claude sub survives VM snapshot | ⬜ | | |
| 1b | Codex device-auth survives snapshot | ⬜ | | |
| 1c | Local `claude -p` works from a spawned process | ⬜ | | |
| 1d | Sign-in still valid at day 3 / day 7 | ⬜ | | |
| 2 | Cron fires in VM with Mac closed | ⬜ | | |
| 2b | Does a *stopped* VM wake for cron? | ⬜ | | |
| 2c | Cost of always-running `small` fallback | ⬜ | | |
| 3 | Exact flag set confirmed | 🟡 | `-p`, `--output-format stream-json`, `--verbose`, `--resume`, `--model`, `--mcp-config` all work. Full `--help` sweep still to do. | 2026-10-02 |
| 3b | Swift incremental stream parse | ✅ | **First event 2.49s into a 10.81s run** — genuinely incremental, no buffering. 7 lines, 0 unknown. | 2026-10-02 |
| 3c | GUI-app `PATH` resolution of engine binary | ✅ | `claude` found at `~/.local/bin/claude` — on **none** of the default system paths. `BinaryResolver` is required, not optional. | 2026-10-02 |
| 3d | Stream schema mapped | ✅ | `system/init`, `assistant` (text + tool_use), `user` (tool_result), `result`, `rate_limit_event`. Sanitised fixture committed. | 2026-10-02 |
| 4 | Claude `PreToolUse` can block and decide | ⬜ | | |
| 4b | Codex / Grok equivalents | ⬜ | | |
| 5 | Resume → first token (median) | ⬜ | | |
| 5b | Cost of a 30-min session | ⬜ | | |
| 6 | SwiftUI orb + beam packages render | ⬜ | | |
| 6b | noVNC desktop in WKWebView | ⬜ | | |

**What each result decides**

- 1 → go / local-only / stop
- 1d → reconnect cadence; whether weekly routines are trustworthy
- **2 → whether the Dots half is real, or whether always-on means an always-running VM**
- 3 → adapter internals and the normaliser fixtures **(done: shell out, parse NDJSON, no SDK)**
- 4 → the highest autonomy level we can honestly offer per engine
- 5 → whether M4 needs pre-warming; what we tell users compute costs
- 6 → build-vs-reimplement for each libraries.dev effect
