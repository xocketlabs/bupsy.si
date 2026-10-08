# Where bupsy is

Plain-language status, by milestone from [PLAN.md](PLAN.md#9-milestones). Update it in the same PR
as the change: a ticked box means it works, has tests where it can, and was checked on screen.

✅ done · 🟡 written but not proven, or partly done · ⬜ not started

**Today (Oct 2026):** M0–M3 done in code; M4–M7 largely done. Launch is blocked only on things
outside the code: an Apple Developer account (signed releases), a boat.dev key (cloud machines),
and a Neon database (waitlist signups).

---

## M0 — Spikes

- ✅ Parse Claude Code's live stream from Swift
- ✅ The approval gate really blocks a command (hook-based, fails closed)
- ✅ Codex through the same adapter (and its sandbox-based enforcement)
- ✅ Latency and real cost measured
- ✅ The Go core, and the shared conformance tests both cores pass
- 🟡 A subscription survives a cloud-machine snapshot — **needs a boat.dev key**
- 🟡 A schedule on a cloud machine survives stop/resume — **needs a boat.dev key**

## M1 — Walking skeleton

- ✅ Native Mac app; a bot runs Claude Code and its reply streams in live
- ✅ Everything stored (SQLite, append-only events) and restored on reopen
- ✅ CI builds a DMG; CI runs on our own Mac runner (no GitHub minutes)
- 🟡 Signed and notarized — **needs an Apple Developer account**

## M2 — The chat app

- ✅ Roster: faces, roles, jobs, folders, pins, hide, search
- ✅ Per bot: engine (Claude Code / Codex), model (aliases, exact versions, custom ID)
- ✅ History and resume, markdown, code blocks, attachments (+ or drop), reply to a message, copy
- ✅ Usage per bot, and the limits card (context window + plan limits with reset times)
- ✅ Codex as a second engine
- 🟡 Cloud machines: create / start / stop / assign — written, **not run against boat.dev yet**
- ⬜ Sign an engine in *on* a cloud machine; watch its screen and files

## M3 — Trust · first shippable build

- ✅ Approval cards: Allow · Deny · Always allow (never for shell commands)
- ✅ Four trust levels; Permissions page to review and remove standing decisions
- ✅ Append-only audit log; Stop; "nobody answered" means no
- ✅ Bot-to-bot messaging asks the first time in each direction

## M4 — Always-on

- ✅ Routines on a schedule, including with bupsy closed (launchd); missed runs catch up once
- ✅ File-change triggers — a bot runs when files in a folder change
- ✅ Attention tray, notifications, menu bar, keep-awake while working
- ✅ Go core for Linux/Windows; installing a schedule on a cloud machine
- 🟡 Work with the lid closed — needs a cloud machine (**boat.dev key**)
- ⬜ Email triggers — today: a routine that checks mail through Executor
- — Webhook triggers: left out on purpose; 1.0 has zero inbound network surface

## M5 — Objectives

- ✅ Standing goals with a done-condition, checked on a schedule
- ✅ Asks rather than guesses; what it learns is plain text you can edit
- ✅ Multiple-choice questions from a bot
- — Grok engine: dropped from 1.0; Claude Code and Codex only

## M6 — Reach

- ✅ Any MCP server as an app; per-bot allowlists; live connection status
- ✅ Executor: one-click install, setup guide, on for every bot
- ✅ Group chats with a lead, @mentions, hand-offs (capped at six replies)
- ✅ Bots message bots, create bots, and act on messages from other bots (looped pairs capped)
- ✅ A busy bot replies in a group when it is free; messages typed while a bot works are queued
- ⬜ Channels (Slack / Telegram) — after 1.0
- ⬜ Computer use — after 1.0

## M7 — Polish & 1.0

- ✅ Onboarding; light / dark / auto; logo and icon; bot creator; thinking indicator
- ✅ Spotlight-style search and new; design notes in [docs/06-design.md](docs/06-design.md)
- ✅ Landing page live at bupsy.pages.dev (white, waitlist form)
- ✅ Release pipeline: tag → DMG on GitHub; CHANGELOG, issue templates, release checklist
- 🟡 Waitlist signups — **needs Neon `DATABASE_URL`**
- 🟡 Signed, notarized, auto-updating releases — **needs an Apple Developer account**
- ⬜ Freestyle as a second cloud host — after 1.0
- ⬜ Custom domain, launch video, announcement

---

## Waiting on you

| What | Unlocks |
|---|---|
| **Apple Developer account** ($99/yr) | Signed DMG that opens with a double-click; auto-updates |
| **boat.dev key** | Cloud machines, lid-closed work, M0's open spikes |
| **Neon `DATABASE_URL`** | Waitlist signups — `wrangler pages secret put DATABASE_URL --project-name bupsy` |
| **Connect tools in Executor** | Gmail, Notion, Linear… for every bot |

## In development (not downloadable yet)

- 🚧 **iPhone app**: native, with notifications when a bot needs you and Face ID to approve. Until it
  ships, a phone uses Bupsy in the browser through the Mac (Settings › Use from other devices).
- 🚧 **Windows / Linux app**: the Go core already runs there; the app is being built.

## Decided against, on purpose

- **Voice**: not in 1.0
- **Webhooks** — would need an inbound port; 1.0 has none
- **Grok engine** — Claude Code and Codex cover 1.0

See [docs/03-decisions.md](docs/03-decisions.md) for why.
