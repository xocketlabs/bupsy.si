# Decision log

Every settled question, with the reasoning. The point is that a team of 3–5 can check what was
decided without asking, and can tell a *decision* from an *assumption nobody challenged*.

Reversing one is fine. Reversing one without reading why it was made is not.

## Settled

| # | Question | Decision | Note |
|---|---|---|---|
| 1 | Relationship to OpenMausBot | Build fresh, no fork | Clean-room rule in CONTRIBUTING.md §2 |
| 2 | Product shape | Chat-first, Grokbot-like | Dots-style objectives layer on top at M5 |
| 3 | Platform | **Native macOS first** (SwiftUI) | Not Electron. The primary differentiator |
| 4 | Licence | **PolyForm Shield 1.0.0** (was BSL 1.1 → Apache-2.0 after 4 years, until 0.2.0) | Licensor: Xocket Labs Inc. (Delaware). [02-licence.md](02-licence.md) |
| 5 | Differentiators | **Three**, not four | Openness claim retired with the licence change |
| 6 | Team | 3–5 → three parallel tracks | Core / App / VM, PLAN.md §9 |
| 7 | Region | EU-only compute is fine | Freestyle stays a hedge at M7, not pulled forward |
| 8 | VM topology | **Separate pools, many-to-one** | Bots have **no machine by default**. PLAN.md §3 |
| 9 | Connectors | MCP now, Composio later | Nothing core may depend on Composio |
| 10 | `bupsy-run` language | Go | Static Linux binary, cross-compiled from macOS |
| 11 | Local store | GRDB / SQLite | Not SwiftData — migrations and append-only logs |
| 12 | macOS minimum | 14 Sonoma | Widest reach |
| 13 | Engines for 1.0 | Claude + Codex | Grok at M5 |
| 14 | API-key mode | Ships quietly in Settings | Required by vendor terms; Gemini proved the need |
| 15 | Repo public | At 1.0 | Private through the risky milestones |
| 16 | Windows / Linux | **macOS first, then reassess** | No public promise either way |
| 17 | Visual identity | libraries.dev `bot-avatars`, ported to SwiftUI | PLAN.md §7 |
| 18 | Monetisation | **Nothing. Not even Sponsors** | BSL preserves the option silently |
| 19 | Telemetry | **None at all** | Updates check only. Say it loudly |
| 20 | Default autonomy | `ask` — gate everything | New bots start fully gated |
| 21 | Voice | After 1.0 | |
| 22 | iOS companion | **Skipped for 1.0** | Decide once the need is demonstrated |
| 23 | Always-on mechanism | **Three tiers** (app open / LaunchAgent / always-on machine) | Corrected twice — see below. PLAN.md §4 |
| 24 | Keeping the Mac awake during a run | **Per bot**, `whileWorking` by default | Free, unprivileged. Prevents idle sleep killing a long run |
| 25 | Privileged wake helper (tier 2b) | **Yes, opt-in in onboarding — post-certificate** | Root daemon with a one-call interface. Threat model in [04-wake-helper.md](04-wake-helper.md) |
| 26 | Distribution | **GitHub Releases only, for now** | Auto-updates deliberately off until a feed has a home — a dead feed is worse than none |
| 27 | Licensor | **Xocket Labs Inc., a Delaware corporation** | Named in LICENSE and NOTICE; a BSL is only enforceable by a named licensor |
| 28 | Windows / Linux | **A headless core, not a second GUI** — and not before macOS 1.0 | See below. Electron was considered and argued against with evidence |
| 29 | Guarding against drift | **Conformance cases, written first** | `conformance/` — one set of cases every implementation must pass |

### Always-on is three tiers, not one (#23)

The plan originally said routines run via cron inside a VM that gets woken from a snapshot, making
always-on nearly free. boat's documentation says stopped sandboxes do not wake for scheduled work,
and hand-started processes do not survive a reboot — so that was simply wrong.

Corrected to three mechanisms the user picks between per routine: **Mac awake** (free, skipped when
asleep), **`pmset` scheduled wake** (free, native-only, "usually works"), and an **always-on machine**
(~$13/mo for a `small`, genuinely independent of the Mac). The machine pool model is what makes the
third affordable — the cost is per machine, and one machine serves every bot assigned to it.

Tier 2 was then corrected a second time: `pmset schedule wake` needs root, so the free middle tier
is a LaunchAgent that runs with the app closed and catches up after sleep, rather than one that
wakes the Mac. That costs us a claimed native advantage — an Electron app can install a LaunchAgent
too — so lid-closed autonomy now rests entirely on tier 3. Said plainly in PLAN.md §4 rather than
quietly softened, because overclaiming there would be the worst lie this product could tell.

Also: **systemd timers, not cron.** And `ttlSeconds` counts from *creation*, not last activity, so
an always-on machine must be created with `ttlSeconds: null` or it disappears after an hour.

## The five worth explaining

### Bots have no machine by default (#8)

Grokbot puts every bot on one shared computer; Dots gives each its own. We decoupled them: a pool
of machines, a roster of bots, assigned many-to-one, and **no machine unless asked for**.

The payoff is not mainly cost. It is that `survivesSleep` stops being a caveat and becomes a
control: a machine-less bot genuinely cannot run routines with the lid closed, the UI says exactly
that, and "assign a machine" is the fix. The limitation and its remedy are the same button.

### Nothing to pay, nothing to sponsor (#18)

No pricing, no Sponsors button, no paid tier, no hosted anything. Combined with #19 this makes the
product unusually easy to describe: there is no account, no server for the app, no app telemetry,
and no way to give us money. BSL keeps commercial licensing available later without promising or building it now.

The honest risk: a team of 3–5 with no revenue is on someone's runway. That is a business decision,
not an engineering one, and it is recorded here so it is not mistaken for an oversight.

### No app telemetry (#19)

The app never phones home except to check for updates. This is verifiable by anyone watching
network traffic, which is what makes it worth saying — an unverifiable privacy claim is marketing.
This decision is about the app; website analytics are a separate choice and must be owner-approved
and disclosed in the website privacy policy.

Cost, accepted deliberately: we fly blind on crashes and on which features get used. Prioritising
the roadmap will depend on talking to people instead of reading dashboards.

### iOS skipped, voice deferred (#21, #22)

Both were M7. Removing them shrinks M7 to polish, onboarding, Freestyle and launch — and removes
the opt-in local HTTP+SSE listener that was the single hole in the no-server design. **1.0 therefore
has zero inbound network surface.** That is a better security story than the one originally planned.

Be honest about the gap it leaves: Grokbot ships a mobile companion and Dots is cross-device by
design. We will claim parity on bots, computers, connectors, schedules and objectives — not on
mobile. If "approve a 3am gate from my phone" turns out to be the thing people actually need, that
is the signal to revisit, and skipping it now is how we find out cheaply rather than by guessing.

### Three differentiators, not four (#5)

Native rather than Electron · lid-closed always-on · MCP-native connectors.

The fourth was "actually all open", aimed at OpenMausBot's proprietary `enterprise/` folder. BSL
forecloses it, because Apache-2.0 would let anyone rebrand and ship bupsy (the same holds under
PolyForm Shield, which replaced BSL after 0.2.0). Retired rather than
softened — a padded list of four reads weaker than a tight list of three.

### Cross-platform: a core, not a second app (#28)

Researched properly rather than assumed. The findings that decided it:

- **Readdle ran this exact experiment.** Spark shared a Swift core with an Electron Windows app
  via a Node addon in 2020, and in 2022 gave up and rebuilt the *Mac* app in Electron too. The
  gravity pulls the native app into the Electron one, not the reverse.
- **Raycast is the version that worked**: one shared core in Rust, a different native shell per
  platform. Nobody ships a shared *Swift* core cross-platform except the project that abandoned it.
- **Our core is ~3,900 lines.** Too small to justify the C-ABI and build machinery Readdle needed
  at 255,000 — but a TypeScript rewrite would be a *third* implementation, because `bupsy-run` is
  already Go (#10) and already reimplements the engine adapter, normaliser and gate.
- **Our own Linux CI job agreed**, independently: our Swift is portable once two Darwin-only APIs
  are replaced, but GRDB does not link there and its Linux support is unmaintained.

So: finish macOS 1.0. If cross-platform demand is real, grow `bupsy-run` into the whole headless
core rather than building a second GUI — it runs on Windows and Linux from day one, and it
*reduces* the number of implementations instead of raising it.

Not a promise either way until 1.0 ships (#16 stands).

### Conformance cases come first (#29)

Before any second implementation, not after. A second core drifts silently, and precisely in the
places a comment explains: markers matched asymmetrically, appends idempotent on `(runID, seq)`,
cron refusing `*/n` where every general-purpose library accepts it.

`conformance/` holds one set of cases every implementation must pass. Verified by deliberately
introducing both of those drifts and confirming the suite fails with the reasoning attached.

### The headless core has no dependencies (#30)

`Tools/bupsy-run` is Go with an empty `go.mod` and no `go.sum`, and that is a decision rather than
an accident. The core's whole job is to spawn other people's binaries and parse their output, and
the standard library covers all of it. A dependency is a thing that can be compromised between us
and a user's machine — in a program that runs with the user's own credentials sitting in files
beside it, that trade is not worth making for a cron parser.

The practical cost is a hand-written cron parser and line scanner. Both already existed in Swift,
and the conformance cases make the second copy cheap to trust.

### A second implementation earns its keep before it ships (#31)

Writing the Go core against `conformance/` found **two live bugs in the shipping Swift core** in
about an hour, neither visible to 146 passing Swift tests:

1. Every Codex run emitted a fatal `protocolError`, because a routine stderr notice was read as a
   hang. There was a unit test for it, and it passed throughout — it asserted the mapping rather
   than the premise behind the mapping.
2. Codex refuses to start outside a git repository, and the explanation was dropped, so a bot
   pointed at an ordinary folder failed with zero events and no reason.

Neither was found by the Go core disagreeing with Swift. Both were found because writing the
mapping a second time meant checking it against the real binary again. That is the argument for
doing this before 1.0 rather than after, and it is recorded here so it is not re-litigated as
"the Go core was a detour".

See docs/01-spikes.md spike 6. The gap that hid finding 1 and 2 — argv and stderr, both of which
fail *before* any event exists — is now two case kinds, `command` and `stderr`.

## Still open

| Question | Blocks | Owner |
|---|---|---|
| **Developer ID certificate** ($99/yr) | notarized releases **and** the tier 2b wake helper | founder |
| **A boat.dev API key** | the cloud host is written but untested against the real service | founder |
| Lawyer review of the Additional Use Grant | not blocking; worth an hour before the first public build | founder |
| ~~Change Date: 4 years or 3?~~ | settled: no conversion; PolyForm Shield replaced BSL | founder |
| Freestyle region list | whether EU-only is permanent | VM |

Answered since this table was first written: spike 2 (a stopped machine does **not** wake for its
own cron — hence the three always-on tiers) and spike 4 (Claude's `PreToolUse` hook does block, in
both directions, against the real binary). Both are written up in docs/01-spikes.md.
