# bupsy.si — end-to-end plan

**A native macOS app. A roster of AI bots you chat with like contacts. Free to use.**

Every bot is a real agent — `claude`, `codex` or `grok` running under your own subscription — with its
own personality, model, cloud computer, and connected apps. Talk to them. Give them standing goals.
They keep working with the lid closed.

Decisions taken: build fresh (no fork), chat-first UI, full Grokbot **and** Dots parity, **native
macOS first** (Swift/SwiftUI, not Electron), source-available under BSL 1.1. Greenfield — nothing written yet.

---

## 1. The competitive read, honestly

| | Grokbot (xAI) | Dots (OpenAI) | OpenMausBot | **bupsy.si** |
|---|---|---|---|---|
| Shape | chat roster | background goals | chat roster | **both** |
| Model access | xAI sub | $500/mo tier | BYO CLI | **BYO CLI** |
| Client | native | native | Electron | **native Swift** |
| Source | closed | closed | open-core (`enterprise/` proprietary) | source-available, BSL 1.1 → Apache-2.0 |
| Always-on when laptop sleeps | yes (cloud) | yes (cloud) | no — local harness | **yes (VM-side scheduler)** |
| Price | sub | $500/mo tier | free + sponsors | **free** |

[OpenMausBot](https://github.com/milind-soni/OpenMausBot) is the incumbent in our exact slot: 3.9k
stars, 671 forks, shipped on macOS/Windows/Ubuntu, already on boat.dev, already has a permission
broker and a Composio marketplace. We are entering against it deliberately. That only works if we
are *structurally* better at something it cannot easily copy, so these four are the whole strategy:

1. **Native, not Electron.** A signed Swift binary with no Node runtime: ~40–60 MB instead of
   ~500 MB, cold launch in well under a second, real Keychain, real notifications, on-device
   dictation, `launchd` integration, no `127.0.0.1` port to collide. An Electron app cannot follow
   us here without a rewrite. This is the most defensible axis and it is visible in the first
   five seconds of use.
2. **Always-on that survives a closed lid.** A local harness stops when the Mac sleeps. We put the
   scheduler **inside the user's own VM**, so routines fire whether the Mac is awake or in a bag.
   This is the Dots half, and §4 is how.
3. **MCP-native, not broker-dependent.** Connectors are MCP servers the user owns, not a hosted
   marketplace account. Works identically on the Mac and in the VM, and needs no third-party key.
   Composio stays available for long-tail reach once there is demand, but nothing core depends on it.

**Three, not four.** An earlier draft claimed openness as a fourth differentiator against
OpenMausBot's `enterprise/` carve-out. We chose BSL 1.1 instead, which forecloses that argument:
Apache-2.0 would let anyone rebrand and ship bupsy, exactly as we could have forked them. The
licence that prevents it is the licence that prevents the claim. Retired rather than weakened —
three real advantages beat four where one is contested. See [docs/02-licence.md](docs/02-licence.md).

**The honest risk:** parity across two products is a very large surface, and OpenMausBot has a
seven-week head start with 661 source files. §9 sequences this so that something genuinely good
ships at M3 even if M4–M7 slip, and the M0 spikes fail fast on the premise before we invest.

**Clean-room rule:** we are building fresh, so **do not read OpenMausBot's source while writing
ours.** Its README, docs and screenshots are fair study. Its code is not — copying Apache-2.0 code
without attribution is a licence violation, and pulling it into a source-available work is messy
even when done correctly, since the attribution obligations survive and that boundary has to be
maintained forever. If we ever decide to take code, we take it deliberately, with
NOTICE attribution, as its own commit. Put this in CONTRIBUTING.md.

---

## 2. What "parity" means concretely

The feature set we are claiming, split by which incumbent it answers:

**Grokbot half — the chat app (M1–M3)**
- Bot roster in a sidebar; bots behave like contacts (pin, unread, duplicate, hide, profile)
- Per-bot persona, engine, and model; switch model mid-thread
- Streaming replies with tool-run activity chips and folded-in screenshots
- Inline approval cards: Allow / Deny / answer in chat
- A cloud computer per account: desktop view, file browser, terminal
- Channels — Work / Personal / per-project, separate transcripts and working folders

**Dots half — the always-on part (M4–M5)**
- **Objectives**: standing outcomes, not one-off tasks ("keep my inbox at zero", "watch these
  three competitors"). The concept Grokbot lacks and OpenMausBot does not model.
- Routines on a schedule, firing VM-side so the Mac can be closed
- Triggers: cron, inbound email per bot, webhook, file-watch, URL-watch
- Memory that improves from feedback across runs
- Minimal-oversight mode with a trust ladder, and an attention inbox for what needs you
- Subscription limit-burn gauge, read from the engine's own `rate_limit_event` (see M2)

**Both (M6–M7)**
- Connectors: Gmail, Calendar, Drive, Slack, Notion, GitHub via MCP
- Computer use — browser automation inside the VM
- Multi-bot teams with a coordinator; bots hand work to each other
- ~~iOS companion for approvals and checking in~~ — **cut from 1.0**
- ~~Voice: spoken replies and calls~~ — **cut from 1.0**

---

## 3. Architecture

Two execution locations, one abstraction. That is the whole design.

```
┌──────────────────────────────────────────────────────────────────┐
│  Bupsy.app  — SwiftUI, macOS 14+, Developer ID, NOT sandboxed    │
│                                                                  │
│  ┌────────────┐ ┌────────────┐ ┌───────────┐ ┌────────────────┐  │
│  │  roster &  │ │  thread &  │ │ computer  │ │  attention     │  │
│  │  channels  │ │  approvals │ │  panel    │ │  inbox         │  │
│  └────────────┘ └────────────┘ └───────────┘ └────────────────┘  │
│  ────────────────────── BupsyKit (SPM) ───────────────────────── │
│  Orchestrator · EventBus(AsyncStream) · Store(GRDB+NDJSON)       │
│  Keychain ─ our keys only (boat, voice). NEVER model creds.      │
│                                                                  │
│  ExecutionHost                                                   │
│   ├── LocalHost   Process+Pipe → claude/codex/grok on this Mac   │
│   └── CloudHost   boat | freestyle REST → same CLIs in the VM    │
└───────────────┬──────────────────────────────┬───────────────────┘
                │ local subprocess             │ REST / SSH / PTY
    ┌───────────▼──────────┐      ┌────────────▼─────────────────────┐
    │ THIS MAC             │      │ USER'S VM (boat, --no-env)       │
    │ ~/.claude ~/.codex   │      │ ~/.claude ~/.codex  ← their own  │
    │ their own logins     │      │ bots/<bot>/ · shared/            │
    │ local files, fast    │      │ cron ← VM-SIDE SCHEDULER         │
    │ stops when asleep    │      │ MCP servers · browser · desktop  │
    └──────────────────────┘      │ runs with the lid closed         │
                                  └──────────────────────────────────┘
```

**No server of ours. Anywhere.** No control plane, no accounts, no backend to breach. The user's
VM is rented with *their own* boat API key. We ship an app; we operate nothing. That is what makes
"free" sustainable and what makes the compliance story in
[docs/00-compliance-and-auth.md](docs/00-compliance-and-auth.md) nearly trivial.

### Machines and bots are separate pools

Neither incumbent's model fits. Grokbot puts every bot on one shared computer; Dots gives each its
own. We decouple them: a user owns a **pool of machines** and a **roster of bots**, and assigns
bots to machines many-to-one. Ten machines, twenty bots, whatever mapping they like.

**A bot has no machine by default.** It runs on the Mac — free, instant, and already holding the
user's local files. A machine gets assigned when a bot actually needs one: a computer to drive, a
toolchain that should not touch the Mac, or routines that must survive a closed lid.

This earns its keep three ways:

- **Nothing is paid for before it is needed.** A roster of chat-only bots costs zero compute. Dots'
  one-VM-per-agent model bills from the first bot.
- **One engine login per machine, not per bot.** Bots sharing a machine share its sign-in. That
  step is our biggest onboarding tax, so paying it per machine rather than per bot matters more
  than it looks.
- **`survivesSleep` becomes a product surface, not a caveat.** A machine-less bot genuinely cannot
  run routines with the lid closed; the UI says so plainly, and "assign a machine" is the one-click
  fix. The honest limitation and its remedy are the same control.

Bots on one machine collaborate through the filesystem with no plumbing — one drops a file in
`shared/`, another picks it up. They get no isolation from each other, which is fine: they are the
same principal. Isolation is what *separate machines* are for, and the user now chooses it per bot.
Per-bot tool allowlists apply either way.

```
   bots (roster)                    machines (pool, may be empty)
   ┌──────────────┐
   │ Inbox        │──────────────▶ ┌──────────────────┐
   │ Researcher   │──────────────▶ │ work  (4c/8G)    │  shared sign-in
   │ Scraper      │──────────────▶ └──────────────────┘
   ├──────────────┤
   │ Builder      │──────────────▶ ┌──────────────────┐
   │              │                │ build (8c/16G)   │  own toolchain
   ├──────────────┤                └──────────────────┘
   │ Notes        │ ── no machine ──▶ this Mac. Free. No lid-closed routines.
   │ Scratch      │ ── no machine ──▶ this Mac.
   └──────────────┘
```

### Data model

Local SQLite via GRDB. The shape that matters is the nullable assignment.

```
machines      id, user_id, name, provider, provider_id, snapshot_id, state, size,
              region, last_active_at, vm_seconds_mtd
              -- a user-owned pool. Zero machines is a valid, common state.
bots          id, name, avatar_seed, persona_md, engine, model,
              machine_id NULL REFERENCES machines,   -- NULL = this Mac only
              workdir, tool_allowlist, autonomy(ask|allowlist|trusted|auto)
engine_links  id, machine_id NULL, engine, status(signedIn|signedOut|unknown),
              method, last_checked_at      -- NULL machine_id = the Mac's own login
                                           -- NEVER a token column
conversations id, bot_id, provider_conv_id, title, last_event_at
runs          id, bot_id, conversation_id, trigger_id, host, status,
              started_at, ended_at, usage, rate_limit_snapshot
events        id, run_id, seq, type, payload, at        -- append-only
triggers      id, bot_id, kind(cron|email|webhook|watch|manual), config,
              enabled, installed_on_machine  -- false ⇒ Mac-awake-only, say so in the UI
approvals     id, run_id, tool, args_redacted, state, decided_at
connectors    id, machine_id NULL, kind, status, scopes  -- status only, no tokens
audit_log     id, actor, action, target, at, meta        -- append-only
```

Three rules to enforce in review: **no column can hold a model credential or connector OAuth
token**; `events` and `audit_log` are append-only; and `bots.machine_id` is nullable *on purpose* —
a machine-less bot is the default, not a broken row, so every host-resolution path must handle it.

### Why native Swift rather than a Node sidecar

OpenMausBot runs a harness server on `127.0.0.1:8799` because an Electron app cannot own long-lived
subprocesses comfortably. We have no such constraint: `Foundation.Process` plus pipes is a better
process supervisor than an HTTP hop, and skipping it buys us no bundled Node, no port conflict, no
localhost attack surface, no "harness failed to start" class of bug, and one signed binary.

Cost: no free localhost API for a companion app. Originally we planned to pay that in M7 with an
opt-in local listener. The companion app is now cut from 1.0, so **we do not pay it at all**: 1.0
has no inbound network surface of any kind. If a companion is ever built, the listener is the price
and it stays off by default.

### Core types

```swift
// Packages/BupsyKit/Sources/Hosts/ExecutionHost.swift
public protocol ExecutionHost: Sendable {
    var id: HostID { get }                       // .local | .cloud(provider:)
    var survivesSleep: Bool { get }              // false for .local — drives UI honesty
    func spawn(_ invocation: EngineInvocation) async throws -> AsyncThrowingStream<Data, Error>
    func read(_ path: String) async throws -> Data
    func write(_ path: String, _ data: Data) async throws
    func installTrigger(_ t: Trigger) async throws // VM-side cron; throws on .local
    func desktopURL() async throws -> URL?
    func wake() async throws                     // resume a stopped VM; no-op locally
    func sleep() async throws                    // snapshot + pause billing
}

// Packages/BupsyKit/Sources/Engines/EngineAdapter.swift
public protocol EngineAdapter: Sendable {
    var id: EngineID { get }                     // .claude | .codex | .grok | .opencode
    /// Is the USER's credential present? Returns a verdict, never the credential.
    func authStatus(on: ExecutionHost) async throws -> AuthStatus
    /// Command for a PTY so the user completes the vendor's own flow themselves.
    func loginCommand() -> LoginCommand
    func invocation(for: RunRequest) -> EngineInvocation
    /// Map this engine's native stdout into our canonical events.
    func normalise(_ chunk: Data) -> [AgentEvent]
    func gate(_ req: ApprovalRequest) async -> ApprovalDecision   // per-engine mechanism
}

public enum AgentEvent: Sendable {
    case text(String), thinking(String)
    case toolCall(ToolCall), toolResult(ToolResult)
    case approvalRequired(ApprovalRequest)
    case usage(Usage), rateLimit(RateLimit)      // ← subscription headroom, from spike 3
    case done(Outcome), failed(EngineFailure)
    case unknown(raw: String)                    // never drop a line we do not model yet
}
```

Everything above `AgentEvent` — UI, transcript, audit log, approval queue — is written once. Every
engine and both hosts plug in beneath it. Get these three types right in week two and the rest of
the project is additive.

**Built and tested** in `Packages/BupsyKit`, verified against the real `claude` binary by M0
spike 3: events stream incrementally (first at 2.49s of a 10.81s run), tool calls and results
round-trip, and unmodelled lines surface as `.unknown` instead of vanishing. `make test`.

### Stack

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI, macOS 14+ | Native is the whole differentiator. AppKit escape hatches where needed. |
| Language | Swift 6, strict concurrency | Actors fit a process supervisor exactly. |
| Store | GRDB (SQLite) + NDJSON per thread | Queryable state; append-only transcripts that survive a crash and are greppable. |
| Secrets | Keychain — *our* keys only | boat/voice keys. Model credentials never touch us. |
| Desktop view | WKWebView over boat's desktop URL | noVNC in a web view; no native VNC client to maintain. |
| Effects | SwiftUI + Metal | See §7 on libraries.dev. |
| Build | SPM packages + XcodeGen | Keeps the project file out of merge conflicts — matters for contributors. |
| Dist | Developer ID, notarized DMG + Sparkle | **Not the Mac App Store.** See below. |
| CI | GitHub Actions, macOS runners | Build, test, notarize, release. |

**Not the Mac App Store, and this is structural:** the App Sandbox cannot spawn arbitrary
user-installed binaries like `claude`. Our entire premise is spawning them. So: Developer ID
signing, hardened runtime, notarization, Sparkle for updates. Budget an Apple Developer account
($99/yr) — the only hard cost in the project.

---

## 4. Always-on: the VM-side scheduler

The single most important design decision, and our answer to Dots.

A local harness is dead when the Mac sleeps. Grokbot and Dots feel magical precisely because the
work continues overnight. We get that without operating any server:

```
user creates a routine ("every weekday 7am, brief me on my inbox")
  → app compiles it to a persona + prompt + schedule
  → installTrigger() writes a crontab entry INSIDE the user's VM:
        0 7 * * 1-5  /usr/local/bin/bupsy-run <bot> <routine-id>
  → `bupsy-run` is our small static binary, installed in the VM:
        invokes the engine CLI with the user's in-VM credentials
        appends canonical events to /home/user/.bupsy/events/<run>.ndjson
        parks anything needing approval in /home/user/.bupsy/pending/
  → Mac asleep, closed, or off. Routine runs anyway.
  → Mac wakes → app reconciles: tails new NDJSON, imports runs,
    raises approvals into the attention inbox, posts notifications
```

Consequences worth being explicit about:

- **The VM is the source of truth for cloud runs.** The Mac is a viewer that catches up. Design the
  store for reconciliation from day one — idempotent run ids, last-synced watermarks.
- **`bupsy-run` is a real deliverable**, not a script. Single Swift or Go static binary, versioned,
  installed into the VM template, upgraded on connect. Keep it tiny and boring.
- **Approvals must degrade.** A routine at 3am that needs permission cannot block forever. Per
  routine: *park and wait* (default), *skip the step*, or *proceed under allowlist*.
- **Sleep the VM between runs.** Wake on cron, work, snapshot, pause billing. boat's own platform
  guide prices this pattern at **$1–5/month** — paid by the user, to boat, directly.
- `survivesSleep` is on `ExecutionHost` so the UI can be honest: a routine assigned to a local bot
  shows "only runs while your Mac is awake," with one click to move it to the cloud.

### Objectives — the Dots concept

A routine fires on a schedule. An **objective** is a standing outcome the bot owns:

```
Objective: "Inbox at zero by 6pm each weekday"
  bot: Inbox · host: cloud · autonomy: allowlist
  checks: weekdays hourly 9–18
  done when: no unhandled mail older than 4h
  escalate: anything needing a decision → attention inbox
  memory: learns which senders I ignore, which I always reply to
```

Modelled as `objective → policy → generated checks → runs`, where the bot decides each check
whether action is needed. This is the hardest thing in the plan and the most differentiated;
M5 owns it. Objectives without a trust ladder are a liability, so §6 ships first.

---

## 5. Engines and the credential boundary

| Engine | User's credential | In-VM / local login | Notes |
|---|---|---|---|
| Claude Code | Pro / Max subscription | `claude` → `/login` in a PTY | Primary. Hooks give us the cleanest approval gate. |
| Codex | ChatGPT Plus / Pro | `codex login --device-auth` | Device flow is built for headless. |
| Grok CLI | xAI subscription | its own flow | Grokbot parity demands it. |
| OpenCode / Kimi | own API key | paste in-place | Fallback if a subscription path closes. |
| ~~Gemini CLI~~ | — | — | Google killed free + AI Pro/Ultra login **2026-06-18**; API key only. Deprioritise. |

Full rules in [docs/00-compliance-and-auth.md](docs/00-compliance-and-auth.md). The one-line version:
**we spawn vendor binaries, we never hold vendor credentials.** Being a local app with no backend
means there is literally nowhere for a credential to leak to — but the rules still bind, because we
distribute a product that runs Claude Code.

Gemini's shutdown is why `EngineAdapter` exists before the second engine does. **Assume any vendor
can close its subscription path with a month's notice.** Four engines makes that an inconvenience.

---

## 6. Trust: the thing that makes autonomy shippable

An agent with your real logins and a cloud computer is dangerous in direct proportion to how
useful it is. Ship the brakes before the accelerator — M3 before M5, no exceptions.

**The ladder, per bot:**

| Level | Behaviour |
|---|---|
| `ask` | Every shell command, file write, and outbound action needs a decision. Default for new bots. |
| `allowlist` | Named tools and paths run free; everything else asks. |
| `trusted` | Reads and in-VM work run free; anything leaving the machine asks. |
| `auto` | Nothing asks. Requires a typed confirmation and is never the default. |

**Mechanism, per engine.** Claude Code gives us `PreToolUse` hooks: a hook script in the VM or on
the Mac calls back over a unix socket and blocks until the user decides — the full gate in a few
lines of config, with no reimplemented agent loop. Codex and Grok have their own approval
configuration; `EngineAdapter.gate` exists so each maps onto the same card in the UI. **Verify each
engine's real mechanism in M0 spike 5** — this abstraction is only as good as its worst engine.

Also non-negotiable: append-only audit log of every tool call and decision; a global kill switch
that stops every run and sleeps every VM; connectors read-only until explicitly widened;
`shared/` as the only path bots can cross into each other's work.

---

## 7. UI

Chat-first, and it should feel like Messages rather than a dashboard. Three panes: roster sidebar,
thread, inspector (computer / files / objectives).

Screens: **Roster** (bots as contacts, live status) · **Thread** (streaming, tool chips, approval
cards) · **Computer** (desktop stream, file tree, terminal, sleep/wake, spend) · **Attention
inbox** (approvals, parked runs, escalations — the Dots surface) · **Objectives & routines** ·
**Connect** (per-engine and per-connector sign-in via PTY) · **Settings**.

### libraries.dev in a native app

Checked this specifically: **Border Beam and Thinking Orbs ship SwiftUI versions** — add them via
SPM and use them directly. The other five are React-only, so they are references to reimplement in
SwiftUI/Metal, not dependencies. All MIT.

| Spot | Library | Status |
|---|---|---|
| Bot is thinking / run streaming | **thinking-orbs** | **SwiftUI — use directly.** Our most-seen animation; runs last minutes. |
| Composer while generating | **border-beam** | **SwiftUI — use directly.** |
| Bot avatars in roster, status-driven | bot-avatars | Reimplement in SwiftUI. Highest-value of the five — it is the roster's whole personality. |
| Voice input / calls | voice | Reimplement; pairs with on-device dictation. |
| Primary CTAs | liquid-metal | Reimplement in Metal, or skip — SF Symbols and materials may be better here. |
| Bots collaborating | gooey | Reimplement as the motif for multi-bot handoff. |
| Image artifacts loading | image-generation | Needs `three`; reimplement in Metal or skip. |

Do not drop a web view in to get the React ones. That forfeits the differentiator to save a week.

---

## 8. Economics

Free to use, source-available, no accounts, no backend, nothing metered by us.

| | |
|---|---|
| Our infra cost | **$0** — we operate nothing |
| Our fixed cost | $99/yr Apple Developer |
| User's compute | their own boat key, $1–5/mo on the wake-on-cron pattern |
| User's models | subscriptions they already hold |
| Monetisation | **None.** No pricing, no Sponsors, no paid tier. BSL keeps commercial licensing available later without promising it now |
| Telemetry | **None.** Update checks only, and verifiable by anyone watching the network |

Against Dots' $500/mo tier: **we have no token COGS and no servers, so we need no price at all.**

The combination is unusually easy to state: no account, no server, no telemetry, and no way to pay
us. The accepted risk is that a team of 3–5 with no revenue is on someone's runway — a business
decision, recorded in [docs/03-decisions.md](docs/03-decisions.md) #18 so it is not mistaken for an
oversight.

---

## 9. Milestones

Sized for a **team of 3–5**, which is what makes 22 weeks plausible. Three tracks run in parallel
once M1 lands, with the `ExecutionHost` / `EngineAdapter` / `AgentEvent` contracts as the seam
between them:

| Track | Owns |
|---|---|
| **Core** | `BupsyKit`: engines, hosts, store, triggers, reconciliation |
| **App** | SwiftUI: roster, threads, approvals, computer panel, onboarding |
| **VM** | `bupsy-run`, machine template, MCP connectors, cloud scheduling |

The contracts exist precisely so these three do not block each other. Agree them in M1 and treat a
change to them as a reviewed interface change, not a refactor.

### M0 — Spikes (week 1). Gate before product code.
Six assumptions hold up everything. [docs/01-spikes.md](docs/01-spikes.md) has the commands.
Headline: **does a subscription survive a VM snapshot** (the premise), **does VM-side cron fire
with the Mac closed** (the Dots half), and **what is each engine's real approval mechanism**.

### M1 — Walking skeleton (weeks 2–4)
SwiftUI shell. `BupsyKit` with the three core types. `LocalHost` spawning `claude -p` and parsing
its stream into `AgentEvent`. One bot, one thread, streaming to the UI. GRDB store + NDJSON.
Signed notarized DMG from CI on day one — never defer release engineering.

### M2 — The chat app (weeks 5–7)
Roster, personas, per-bot engine/model, model picker, thread history and resume, tool-run chips,
markdown, attachments. `CloudHost` on boat: provision, PTY login, desktop panel, file tree.
Second engine (Codex) proving the adapter.

**Pulled forward from M5:** the limit-burn gauge. Spike 3 found `claude` emitting its own
`rate_limit_event` with per-window utilisation, so this is now a readout rather than an estimate —
cheap enough to ship with the chat app, and it protects the user's account from their own bots.

### M3 — Trust (weeks 8–9) · **first genuinely shippable build**
Approval cards, the four-level ladder, hook-based gating per engine, audit log, kill switch.
**Public v0.1 here.** A native Mac app where you chat with Claude and Codex bots that have a cloud
computer and ask before they act is already worth shipping, and the feedback shapes M4+.

### M4 — Always-on (weeks 10–12)
`bupsy-run` binary, VM-side cron installer, reconciliation on wake, triggers (cron, email, webhook,
watch), attention inbox, notifications, auto-sleep. **The lid-closed demo** — our best video.

### M5 — Objectives (weeks 13–15)
Standing outcomes, generated checks, done-conditions, escalation policy, memory that learns from
feedback. The Dots half proper. Third engine (Grok) for Grokbot parity.

### M6 — Reach (weeks 16–18)
MCP connectors (Gmail, Calendar, Drive, Slack, Notion, GitHub) with in-VM OAuth, per-bot tool
allowlists, computer use, channels, multi-bot teams with a coordinator.

### M7 — Polish & 1.0 (weeks 19–22)
Onboarding that survives the sign-in step. Freestyle as second `CloudHost`. Signed, notarized,
auto-updating release. Docs, site, launch.

**Deliberately out of scope for 1.0:** the iOS companion and voice (both cut — see
[docs/03-decisions.md](docs/03-decisions.md) #21–22), Windows and Linux (macOS first, reassess
after), teams/multi-user, hosted anything, a bot marketplace, any monetisation at all.

Cutting the companion app removes the opt-in local HTTP+SSE listener it needed, so **1.0 ships with
zero inbound network surface.** That is a better security story than the one first planned, and it
is worth saying out loud in the launch copy.

Be honest about the gap: Grokbot ships a mobile companion and Dots is cross-device by design. We
claim parity on bots, computers, connectors, schedules and objectives — not on mobile.

---

## 10. Repo layout

```
bupsy.si/
  Apps/BupsyMac/             SwiftUI app target
  Apps/BupsyiOS/             companion (M7)
  Packages/BupsyKit/
    Sources/Engines/         claude · codex · grok · opencode adapters
    Sources/Hosts/           LocalHost · CloudHost(boat, freestyle)
    Sources/Events/          AgentEvent + per-engine normalisers
    Sources/Triggers/        routines, objectives, VM-side cron installer
    Sources/Connectors/      MCP client + registry
    Sources/Store/           GRDB schema, NDJSON transcripts, reconciliation
    Tests/
  Packages/BupsyUI/          shared SwiftUI components and effects
  Tools/bupsy-run/           static binary that runs inside the user's VM
  vm/                        VM template build: engines, MCP servers, bupsy-run
  docs/
  project.yml                XcodeGen
```

---

## 11. Open decisions

All nineteen framing questions are settled and recorded, with reasoning, in
**[docs/03-decisions.md](docs/03-decisions.md)**. What remains genuinely open:

| Question | Blocks |
|---|---|
| `<LICENSOR>` legal entity + lawyer review of the Use Grant | repo going public, any shipped build |
| **Spike 2: does a stopped VM wake for its own cron?** | the always-on architecture |
| Each engine's real blocking approval mechanism (spike 4) | autonomy above `ask` |
| Freestyle region list | whether EU-only is permanent |

### Superseded — kept for the reasoning

**Settled since first draft:** machines and bots are separate pools with nullable assignment (§3);
EU-only compute is acceptable, so Freestyle stays a hedge at M7; team of 3–5, so milestones run as
three parallel tracks (§9).

1. **Connector layer** — MCP-only (open, no third-party key, works in both hosts) or add Composio
   for long-tail reach? Recommend MCP-only through 1.0.
2. **`bupsy-run` language** — Swift static binary (one language) or Go (smaller, trivially
   cross-compiled for the Linux VM)? Lean Go for the VM side.
3. ~~**Licence**~~ — *settled: BSL 1.1, converting to Apache-2.0 after four years. The remaining
   open item is the `<LICENSOR>` legal entity and a lawyer's review — see docs/02-licence.md.*
4. **Windows/Linux** — never, community-maintained, or post-1.0? Say it publicly either way.

---

## Sources

- [Anthropic — Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) — the hosting carve-out and credential prohibitions
- [Anthropic — Agent SDK overview](https://code.claude.com/docs/en/agent-sdk) — no claude.ai login for third-party products
- [boat.dev](https://docs.boat.dev/quickstart) · [platform guide](https://docs.boat.dev/platform-guide.md) · [integrated agents](https://docs.boat.dev/integrated-agents.md) · [API v1](https://docs.boat.dev/api/v1.md)
- [Freestyle](https://www.freestyle.sh/docs) · [Claude Code in a sandbox](https://www.freestyle.sh/docs/guides/run-claude-code-in-a-sandbox.md) · [pricing](https://www.freestyle.sh/pricing)
- [Codex CLI authentication](https://learn.chatgpt.com/docs/auth) — `--device-auth`, `auth.json`
- [libraries.dev](https://libraries.dev) — Beam and Orb have SwiftUI support; the rest are React
- [OpenMausBot](https://github.com/milind-soni/OpenMausBot) · [its LICENSING.md](https://github.com/milind-soni/OpenMausBot/blob/main/LICENSING.md) — open-core boundary and trademark terms
- [TechCrunch — OpenAI launches Dots](https://techcrunch.com/2026/09/29/openai-launches-dots-its-bubbly-agentic-avatar/) · [Bloomberg — the $500 tier](https://www.bloomberg.com/news/articles/2026-09-29/openai-unveils-always-on-ai-agent-dots-new-500-paid-tier)
- [Grokbot overview](https://www.mindstudio.ai/blog/grokbot-xai-agent-app)
- [Gemini CLI free tier shutdown, 2026-06-18](https://dev.to/owen_fox/gemini-cli-free-tier-shut-down-6-fixes-that-work-2026-26hc)
