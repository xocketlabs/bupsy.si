<div align="center">

<img src="docs/logo.png" width="128" alt="Bupsy app icon">

# Bupsy

**A Mac app where your AI bots live. They use the subscriptions you already pay for.**

[![CI](https://github.com/xocketlabs/bupsy.si/actions/workflows/ci.yml/badge.svg)](https://github.com/xocketlabs/bupsy.si/actions/workflows/ci.yml)
[![Licence: PolyForm Shield 1.0.0](https://img.shields.io/badge/licence-PolyForm%20Shield%201.0.0-blue)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

[Website](https://bupsy.pages.dev) · [Download](https://github.com/xocketlabs/bupsy.si/releases/latest) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

</div>

![Bupsy: a new bot names itself, hands work to another bot, and a routine runs](docs/demo.gif)

Each bot is a real agent: `claude` or `codex` running under **your own sign-in**, on your Mac or
on a machine you rent. Give one a job, a schedule, or a standing goal. They hand work to each other,
and they ask before they act.

> **Early access.** In daily use, not yet Apple-signed. Download the DMG from
> [Releases](https://github.com/xocketlabs/bupsy.si/releases/latest), or build from source. See
> [CHECKLIST.md](CHECKLIST.md) for exactly what is and is not done.

## Install

1. Download **Bupsy.dmg** from the [latest release](https://github.com/xocketlabs/bupsy.si/releases/latest),
   open it, and drag **Bupsy** into **Applications**.
2. The first time, macOS says it can't check the app for malicious software, because the build is
   not notarized yet. Open **System Settings › Privacy & Security**, scroll down, and click
   **Open Anyway** next to Bupsy. You only do this once.
3. Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or
   [Codex](https://github.com/openai/codex) and sign in once. Bupsy finds it.
4. Click **+**. Your new bot asks what it's for, names itself, and gets to work.

Requires macOS 14 or later, on Apple silicon or Intel.

## Why this exists

Agent products from model vendors are closed by construction: one model, one price floor, your
work on their servers. bupsy is the opposite shape.

- **Bring your own agent.** Bots run the CLIs already on your Mac, under subscriptions you already
  hold. No bupsy account, no credits, no proxy in the middle.
- **No servers. Ours, anyway.** There is no bupsy backend. Transcripts are local files; a bot's
  cloud machine is rented with your own key. Nothing to breach, nothing to shut down.
- **Native, not Electron.** A signed Swift app that opens instantly.
- **Always-on that means it.** Routines can run inside your own machine, so they fire whether your
  Mac is awake, asleep, or in a bag.

## What a bot can do

| | |
|---|---|
| **Chat** | Claude Code or Codex, switchable per bot, each keeping its own thread. Bubbles, tables, code with a Run button, attachments, replies, voice in and out |
| **Teamwork** | Bots message each other, hand work on, create new bots, file bots into sections, and change each other's job, model or chat — within the trust you give them |
| **Routines** | "Brief me every weekday at 7am" — runs with the app closed. Bots can schedule them too |
| **Standing goals** | "My inbox has nothing older than a day" — it checks, and acts only when something is off |
| **Fresh chat** | A long chat moves on to a new one from the bot's own hand-off notes, by button or by itself, so each message costs far less |
| **Commands** | Type `/` for Bupsy's own commands, your Claude Code commands and skills, or your Codex prompts |
| **Your apps** | Any MCP server — GitHub, Slack, Notion, files |
| **Ask first** | Four trust levels, from "ask me everything" to "never ask" |
| **Carry on from Claude Code** | Pick a conversation from VS Code or the terminal and it becomes a bot that remembers it |
| **Your other devices** | Use Bupsy from your phone or another Mac over Tailscale; link Macs to see their bots, and move a bot or a whole section to another Mac |
| **A computer** *(beta)* | Give a bot a cloud machine so its work survives a closed lid |

## Credentials

bupsy **spawns vendor binaries and never holds vendor credentials.** Signing in happens in a
terminal we render but do not read; the credential lands in files owned by you and the CLI. There
is no column in this codebase that could hold one, and a test walks the live database schema to
prove it.

The same rule shapes connectors: MCP config references environment variables **by name**, never by
value, so a token never passes through a file we wrote. That is more setup than a paste box would
be, and the app says so rather than hiding it.

Read [docs/00-compliance-and-auth.md](docs/00-compliance-and-auth.md) before touching anything that
authenticates. It quotes the vendor terms the design is built around.

## Platforms

| Platform | Status |
|---|---|
| **Mac** (macOS 14+) | The app. Everything happens here. |
| **Phone and other Macs** | In the browser, through your Mac over Tailscale: Settings › Use from other devices. Linked Macs show each other's bots and can move bots between them. |
| **iPhone app** | 🚧 In development. Not available to download yet. |
| **Windows and Linux** | 🚧 In development. Not available to download yet. The Go core (`bupsy-run`) already runs there. |

## Build it

Requires macOS 14+, Xcode 16 with Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
The headless core needs Go 1.24.

```bash
brew install xcodegen
make run      # generate the project, build and launch
make test     # the BupsyKit tests
make spike    # drive your real claude binary and watch the event stream
```

You will need `claude` or `codex` installed and signed in. Bupsy detects whichever you have.
`./scripts/ci-local.sh` runs what CI runs.

## Project layout

| Path | What it is |
|---|---|
| [`Apps/BupsyMac`](Apps/BupsyMac) | The Mac app (SwiftUI) |
| [`Apps/BupsyiOS`](Apps/BupsyiOS) | The iPhone app, in development |
| [`Packages/BupsyKit`](Packages/BupsyKit) | The core: engines, hosts, approval gate, store, remote access |
| [`Tools/bupsy-run`](Tools/bupsy-run) | The headless core in Go, for Linux and Windows, plus `bupsy-mcp`, the tools bots use to talk to Bupsy |
| [`conformance`](conformance) | Shared test cases both cores must agree on |
| [`site`](site), [`functions`](functions) | bupsy.pages.dev: the landing page, download form and MCP server |
| [`docs`](docs) | Compliance, decisions, design, release process |

## How it works

A SwiftUI app wraps `BupsyKit`, which owns two abstractions:

- **`ExecutionHost`** — where work runs: this Mac, or a machine you rent.
- **`EngineAdapter`** — one per CLI. Spawns the published binary and normalises its native output
  into one `AgentEvent` type.

Everything above that line — chat, transcript, audit log, approval gate — is written once, and
every engine and host plugs in beneath it. [PLAN.md](PLAN.md) has the long version.

## Docs

- [docs/00-compliance-and-auth.md](docs/00-compliance-and-auth.md): how Bupsy stays inside each vendor's terms
- [docs/03-decisions.md](docs/03-decisions.md): what we chose, and what we left out on purpose
- [docs/06-design.md](docs/06-design.md): the design system
- [docs/05-release.md](docs/05-release.md): how a release is cut
- [PLAN.md](PLAN.md) and [CHECKLIST.md](CHECKLIST.md): the plan, and where it stands

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: a few of its
rules (never hold a vendor credential, clean room) are not negotiable. Contributions need the
one-time [CLA](CLA.md). Everyone follows the [Code of Conduct](CODE_OF_CONDUCT.md). Report security
problems privately, as [SECURITY.md](SECURITY.md) describes.

## Licence

**Source-available** under the [PolyForm Shield License 1.0.0](LICENSE). Licensed by Xocket Labs
Inc., a Delaware corporation, part of [Xocket Foundry](https://xocket.sh/foundry).

Use it free, personally or at work. Read it, change it, build it, share it. What you may not do is
use it to make a product that competes with Bupsy: a fork, a clone, a rebranded or hosted version,
paid or free. That rule does not expire. This is not an open-source licence by the OSI definition
and we do not call it one; [docs/02-licence.md](docs/02-licence.md) explains the choice. Version
0.2.0 and earlier were published under the Business Source License 1.1, which still applies to
those versions. Third-party components keep their own licences; see [NOTICE](NOTICE).

---

Not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, xAI or any other vendor.
Product names are their owners' trademarks, used only to say which tools bupsy runs.
