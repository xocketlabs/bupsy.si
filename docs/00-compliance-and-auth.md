# Compliance, licensing, and the credential boundary

> Read before writing anything that touches authentication, process spawning, or the VM template.
> Every rule traces to a published term, quoted below.

## The one-sentence rule

**bupsy spawns vendor binaries. bupsy never holds vendor credentials.**

Being a local app with no backend means there is nowhere for a credential to leak *to* — we have no
server, no database, no account system. That is a structural advantage, not an excuse: we still
distribute a product that runs Claude Code, so the vendor terms still bind us.

---

## What Anthropic permits

From [Claude Code — Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance):

> Unless we've mutually agreed otherwise, preinstalling or running Claude Code in your products or
> services (e.g. in hosted sandboxes or other agent infrastructure) requires agreeing to our
> Commercial Terms of Service and complying with the conditions below:
>
> - **The Claude Code binary must not be modified.** […] customers may not remove, disable, or
>   restrict any authentication method built into it (including methods that permit signing in with
>   a Claude account or the user's own API key).
> - **Customers may not pay for, resell, or intermediate Claude usage on their end users' behalf.**
>   Each end user must authenticate with their own Anthropic API key, Claude subscription plan
>   credentials, or 3P inference provider credential […]

And the sentence the product stands on:

> Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their
> own Claude subscription, including where a platform hosts Claude Code as described under *Can
> customers offer Claude Code in their products?* above.

The prohibitions:

> Anthropic does not permit third-party developers to offer Claude.ai login into their own
> applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their
> users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or
> session tokens — sign-in to a Claude account must complete through Anthropic's own flow.

Also: *"Advertised usage limits for Pro and Max plans assume ordinary, individual usage."* An
objective checking hourly, forever, tests that assumption — hence the limit-burn display in M5.
It protects the user's account, which protects the project.

### Action items

- [ ] **Agree to Anthropic's [Commercial Terms of Service](https://www.anthropic.com/legal/commercial-terms).**
      We run Claude Code in a product. Blocker for public v0.1, not for M0. Owner: maintainer.
- [ ] Re-read both Anthropic's and OpenAI's terms **monthly**; log the date at the bottom of this file.

---

## The rules

### 1. Credentials are born and die where the user put them

Logins happen in a PTY we render but never parse. On the Mac, `~/.claude` and `~/.codex/auth.json`
belong to the CLIs and the user's own account. In the VM, they live on the user's own disk.

```
✅  user clicks "Connect Claude"
    → PTY (local shell, or SSH into their VM)
    → `claude` → /login → they complete Anthropic's flow in their own browser
    → we record EngineLink.status = .signedIn. That is the only thing we learn.

❌  reading ~/.claude or auth.json for any reason, including checking expiry
❌  running `claude setup-token` on the user's behalf and storing the result
❌  putting a credential in our Keychain item, our SQLite store, or any log
❌  a "Sign in with Claude" button anywhere in bupsy
❌  copying credentials between hosts — Mac→VM, VM→VM, or VM→Mac
```

The last one has a sharp edge: **`fork` copies a VM's disk, and the disk contains credentials.**
Forking is only ever within one user's own account, and the VM template we build must contain no
engine credentials.

Checking status: use the CLI's own command (`codex login status`, or a trivial `claude -p` probe)
and keep **only its verdict**. Never the file.

### 2. Ship the binaries unmodified, and prefer not to ship them at all

- **On the Mac:** detect what the user already has (`which claude`). Offer a link to the official
  installer. Do not vendor, patch, or repackage. Settings → Engines lets them point at a custom
  binary path; never hide that.
- **In the VM:** boat preinstalls Claude Code, Codex and others and keeps them updated — prefer
  that over installing ourselves. Where we must install into a template, use each vendor's official
  installer, triggered by an explicit user action, never silently baked in.

Never remove or hide a built-in auth method — including API-key mode, even when it would make the
"no credits" story cleaner. The terms forbid restricting it.

### 3. Never hold a model credential that serves anyone's work

bupsy holds no Anthropic, OpenAI or xAI inference key. Not pooled, not for a trial, not as a
fallback when a user is rate-limited. There is no compliant shortcut for a demo — solve it with a
recorded transcript or sample data, never with our key.

### 4. Shell out; do not embed an SDK under subscription auth

The Claude adapter spawns the real CLI:

```
claude -p "<prompt>" --output-format stream-json --verbose
```

Per [the Agent SDK overview](https://code.claude.com/docs/en/agent-sdk): *"Anthropic does not allow
third party developers to offer claude.ai login or rate limits for their products, including agents
built on the Claude Agent SDK."* The SDK is permitted only under an API key the user supplied — and
even then, one code path is better, so we always shell out.

### 5. Names and marks

Permitted, in plain text: "bupsy runs Claude Code, Codex and Grok." "Works with the CLIs you
already have."

Not permitted: Claude · Anthropic · OpenAI · Codex · xAI · Grok in our product name, feature names,
or logo; anything implying partnership or endorsement; Claude-Code-style ASCII art or visual mimicry.
Engine pickers show the vendor's plain name and nothing more.

Also not permitted: **OpenMausBot · Maus · SupaMaus** — trademarks of Milind Soni, and the Apache
licence grants no trademark rights.

---

## OpenAI / Codex

[Codex CLI auth](https://learn.chatgpt.com/docs/auth) gives us a cleaner headless path:

```bash
codex login --device-auth     # prints a code the user completes in their own browser
codex login status            # our health check — a verdict, not a token
```

Credentials cache at `~/.codex/auth.json`, or a keyring per `cli_auth_credentials_store` in
`config.toml`. In the VM, set `cli_auth_credentials_store = "file"` so sign-in survives snapshots
predictably. OpenAI's docs call the file password-equivalent: *"Treat this file like a password […]
Don't commit it, paste it into tickets, or share it in chat."*

Their docs do mention copying `auth.json` between machines for trusted CI. **We never use that
affordance** — a credential that travels is a credential we are intermediating.

OpenAI has published no equivalent of Anthropic's explicit hosting carve-out, so **treat the Codex
path as less legally settled than the Claude path.** No flow may depend on it alone.

---

## Gemini: the warning

Google shut off the hosted Gemini CLI backend for free accounts, AI Pro and AI Ultra on
**2026-06-18**, moving those tiers to Antigravity CLI. The binary still works — on a paid API key
only. An entire subscription-backed path vanished for everyone in one announcement.

Design consequence: **assume any single vendor can close its subscription path with a month's
notice.** This is why `EngineAdapter` exists before the second engine does, why API-key mode is a
first-class fallback, and why no feature may depend on exactly one vendor.

---

## Our own licence, and the clean-room rule

bupsy is **source-available under the PolyForm Shield License 1.0.0** (0.2.0 and earlier: BSL 1.1). It is not an open-source licence by the OSI definition and we never call it one — see
[02-licence.md](02-licence.md) for the reasoning and the copy rules.

**Do not read OpenMausBot's source code while writing ours.** Its README, docs, screenshots and
public discussion are fair study. Its 661 source files are not. Two reasons:

1. **Licence hygiene.** Apache-2.0 permits reuse *with* attribution and NOTICE obligations.
   Reading-then-reimplementing without attribution creates a provenance claim we cannot defend, in
   a project we want companies to adopt.
2. **It is also just better engineering.** We are making a different bet — native Swift, VM-side
   scheduling, MCP connectors. Their Electron/TypeScript/Composio solutions will pull us toward
   their architecture, which is the one we are trying to beat.

If we ever want their code, we take it deliberately: its own commit, NOTICE attribution, licence
header preserved, called out in the PR. Put this rule in CONTRIBUTING.md.

Third-party obligations we will carry: noVNC (MPL-2.0) if we embed the desktop viewer, Sparkle
(MIT), GRDB (MIT), libraries.dev packages (MIT). BSL governs our code only; theirs keeps its terms. Maintain `NOTICE` and `third_party/` from the first
dependency, not retroactively.

---

## Distribution and security posture

We cannot use the App Sandbox — it cannot spawn arbitrary user-installed binaries, and that is our
entire premise. So we ship a Developer-ID-signed, hardened-runtime, notarized DMG outside the Mac
App Store, and we carry the responsibility that comes with an unsandboxed app that executes
processes and holds a cloud API key:

- [ ] Hardened runtime; entitlements minimal and documented in-repo with a reason for each
- [ ] Notarized in CI; reproducible build steps published
- [ ] Our Keychain items scoped to this app, holding only the user's boat/voice keys
- [ ] No app telemetry. Website analytics, if owner-approved, are covered by the website privacy policy.
- [ ] `SECURITY.md` with a reporting path before v0.1 is public
- [ ] Never execute a path from untrusted data; engine binary paths come from `which` or explicit
      user choice, never from a persona, a team file, or model output

---

## Engineering checklist (enforce in review)

- [ ] No DB column, Keychain item, log line, or crash report can hold a model credential.
      `EngineLink` stores **status only**.
- [ ] No code reads `~/.claude`, `~/.codex`, or any credential path — not even for expiry.
- [ ] PTY sessions are never recorded, scraped, or persisted.
- [ ] VM template contains no engine credentials; `fork` is confined to one user's account.
- [ ] Every engine exposes its API-key path in the UI; none is hidden.
- [ ] Engine binaries are detected or installed by official installer, never vendored or patched.
- [ ] No OpenMausBot source in our history. No vendor or OMB marks in names, assets, or copy.
- [ ] `NOTICE` and `third_party/` updated in the same PR as any new dependency.

## If a vendor term changes

1. Ship a release that disables new sign-ups on the affected engine; leave existing users running.
2. Notify in-app with the specific change and the user's options.
3. Flip that engine's default to API-key mode.
4. Re-weight onboarding toward the remaining compliant engines.

**Terms last reviewed:** 2026-10-02 (Anthropic, OpenAI). They moved twice in 2026.
