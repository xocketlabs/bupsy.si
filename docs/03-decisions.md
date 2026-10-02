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
| 4 | Licence | **BSL 1.1 → Apache-2.0 after 4 years** | [02-licence.md](02-licence.md). `<LICENSOR>` still open |
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
| 23 | Always-on mechanism | **Three tiers** (Mac-awake / `pmset` wake / always-on machine) | Corrected after boat docs contradicted the original design. PLAN.md §4 |

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
product unusually easy to describe: there is no account, no server, no telemetry, and no way to
give us money. BSL keeps commercial licensing available later without promising or building it now.

The honest risk: a team of 3–5 with no revenue is on someone's runway. That is a business decision,
not an engineering one, and it is recorded here so it is not mistaken for an oversight.

### No telemetry at all (#19)

The app never phones home except to check for updates. This is verifiable by anyone watching
network traffic, which is what makes it worth saying — an unverifiable privacy claim is marketing.

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
forecloses it, because Apache-2.0 would let anyone rebrand and ship bupsy. Retired rather than
softened — a padded list of four reads weaker than a tight list of three.

## Still open

| Question | Blocks | Owner |
|---|---|---|
| `<LICENSOR>` legal entity in `LICENSE` | repo going public, any distributed build | founder |
| Lawyer review of the Additional Use Grant | same | founder |
| Change Date: 4 years or 3? | nothing yet | founder |
| **Spike 2: does a stopped VM wake for its own cron?** | the always-on architecture | Core/VM |
| Each engine's real blocking approval mechanism (spike 4) | the autonomy ladder above `ask` | Core |
| Freestyle region list | whether EU-only is permanent | VM |
