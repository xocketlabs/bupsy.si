# bupsy.si

**A native macOS app. A roster of AI bots you chat with like contacts. Free and open source.**

Every bot is a real agent — `claude`, `codex` or `grok` running on **your own subscription** —
with its own personality, model, cloud computer and connected apps. Talk to them like coworkers.
Give them standing goals. They keep working with the lid closed.

> Status: **pre-alpha.** The architecture is designed ([PLAN.md](PLAN.md)) and the core of the
> engine layer is building and tested. The M0 spikes that gate the product premise are in
> progress — see [docs/01-spikes.md](docs/01-spikes.md). Nothing is installable yet.

## Why

Agent products from model vendors are closed by construction: one model, one price floor, your
work living on their servers. bupsy takes the opposite shape.

- **Bring your own agent.** Bots run the CLIs already on your Mac, under the subscriptions you
  already pay for. No proxy, no credits, no new account.
- **No servers. Ours, anyway.** There is no bupsy backend. Your transcripts are local files;
  your bots' cloud computers are rented with your own key. Nothing to breach, nothing to shut down.
- **Native, not Electron.** A signed Swift app, tens of megabytes, launching instantly.
- **Always-on that means it.** Routines are scheduled inside your own VM, so they fire whether
  your Mac is open, closed, or in a bag.
- **Actually all open.** Apache-2.0, no `enterprise/` folder, no licence keys, no feature gates.

## Architecture in one paragraph

A SwiftUI app wraps `BupsyKit`, which owns two abstractions: an **`ExecutionHost`** (this Mac, or
your own cloud VM) and an **`EngineAdapter`** (one per CLI harness). Adapters spawn the published
vendor binary and normalise its native output stream into one canonical `AgentEvent` type.
Everything above that line — chat, transcript, audit log, approval queue — is written once.
See [PLAN.md](PLAN.md) §3.

## Build

Requires macOS 14+ and Swift 6.

```bash
make test        # build and test BupsyKit
make spike       # run the M0 spike-3 harness against your local claude CLI
```

## Credentials

bupsy **spawns vendor binaries and never holds vendor credentials.** Sign-in happens in a
terminal we render but do not read; the credential lands in files owned by you and the CLI.
There is no column in this codebase that could hold one. The rules, and the vendor terms they
come from, are in [docs/00-compliance-and-auth.md](docs/00-compliance-and-auth.md) — read it
before touching anything that authenticates.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). One rule up front: **do not copy code from similar
projects into this one.** The reasons are in that file and they are not merely legal.

## Licence

[Apache-2.0](LICENSE), with no carve-out.

Not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, xAI, or any other vendor.
Product names are their owners' trademarks and are used only to say, factually, which tools
bupsy runs.
