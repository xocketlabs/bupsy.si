# Contributing to bupsy.si

Thanks for considering it. This project has a small number of rules that are load-bearing rather
than decorative, so they come first.

## The rules that are not negotiable

### 1. Never hold a vendor credential

bupsy spawns engine binaries; it never reads, stores, forwards or mints their credentials. No
database column, Keychain item, log line, crash report or environment variable may contain one —
not even to check an expiry date. Use the engine's own status command and keep only its verdict.

This is not caution for its own sake. It is the condition under which the product is permitted to
exist at all: vendors allow an end user to sign into an unmodified binary on a host someone else
provides, and forbid third parties from collecting or intermediating those credentials. Read
[docs/00-compliance-and-auth.md](docs/00-compliance-and-auth.md) before writing anything that
authenticates. A PR that crosses this line will be closed rather than revised.

### 2. Clean room — do not copy from similar projects

Do not copy code into this repository from other agent-fleet projects, and prefer not to read
their source while writing ours. Their READMEs, docs and public discussion are fair study.

This rule got *stricter* when we moved to BSL, not looser. Pulling Apache-2.0 code into a
source-available work is legally possible but genuinely messy: the attribution and NOTICE
obligations survive, those files keep their own terms, and that boundary has to be maintained
for the life of the project.

Two reasons:

- **Provenance.** Permissive licences allow reuse *with* attribution and NOTICE obligations.
  Reading-then-reimplementing without attribution creates a claim we cannot defend, in a project
  we want other people and companies to adopt freely.
- **Engineering.** We are making different bets — native Swift, VM-side scheduling, MCP
  connectors. Borrowed solutions drag the design toward the architecture they were written for.

If we ever want third-party code, we take it deliberately: its own commit, licence header
preserved, `NOTICE` updated, called out in the PR description.

### 3. Ship vendor binaries unmodified, and never hide an auth method

We detect and invoke; we do not vendor, patch or repackage. Settings must always expose each
engine's own authentication paths, including API-key mode, even where hiding it would make our
messaging cleaner.

## Working agreements

- **Swift 6 language mode, strict concurrency.** If you need `@unchecked Sendable`, confine it to
  the smallest possible type and comment why it is safe. `ProcessBox` in `LocalHost.swift` is the
  pattern to follow.
- **Never drop input.** Engine stream schemas are partly undocumented and change between releases.
  Decode permissively and map unrecognised lines to `.unknown` so a schema change becomes visible
  in the transcript rather than a silent omission. Tests enforce this.
- **Fixtures over guesses.** When you learn a real stream shape, add it to
  `Tests/BupsyKitTests/Fixtures/` — sanitised, with no account identifiers, paths or tool
  inventories from a real machine.
- **Be honest in the UI.** `survivesSleep`, `maximumEnforceableAutonomy` and the limit-burn gauge
  exist so the app can tell the truth about what it can and cannot guarantee. Do not paper over a
  limitation in copy.
- **No telemetry.** Not opt-out, not anonymised. This is a local-first privacy tool.

## Security

Found a vulnerability? Report it privately: see [SECURITY.md](SECURITY.md). Please don't open a
public issue.

## Conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Process

1. Open an issue first for anything beyond a small fix, so we agree on the shape.
2. Branch from `main`: `feat/…`, `fix/…`, `docs/…`.
3. `make test` must pass. New behaviour needs a test.
4. Open a PR describing *why*, not just what, and tick the CLA box. Note any new dependency and
   update `NOTICE`.
5. Squash-merge once review passes.

## Licence and the CLA

bupsy.si is source-available under [BSL 1.1](LICENSE), converting to Apache-2.0 four years after
each version is published.

Contributions require a one-time CLA: read [CLA.md](CLA.md) and tick its box in your first pull
request. The reason is mechanical rather than defensive: the Licensor
has to be able to relicense the work for that automatic Apache-2.0 conversion to happen at all, and
a contribution with no agreement attached would be code we cannot convert — quietly breaking the
promise the licence makes.

An earlier version of this file said "No CLA, and there will never be one." That was written when
the project was going to be Apache-2.0, and it is retracted here, before anyone had relied on it.
If you contributed under the old wording, say so and we will honour it.

What the CLA does **not** do: there is no paid tier, no `enterprise/` folder, and no plan for
either. See [docs/02-licence.md](docs/02-licence.md).
