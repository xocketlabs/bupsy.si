# Tier 2b: the privileged wake helper

> Approved in principle as an **opt-in** during onboarding. Not built yet, and not shippable until
> the app has a Developer ID certificate. This document is the design and, more importantly, the
> threat model — because the thing being proposed is a root daemon inside an application that
> spawns AI agents holding the user's credentials.

## Why it has to be privileged

Waking a sleeping Mac requires root. That was established at the API, not guessed from a CLI:

```
$ pmset schedule wake "10/02/26 21:05:00"
pmset: This operation must be run as root

# and underneath pmset, from an ordinary process:
IOPMSchedulePowerEvent(…, kIOPMAutoWake)        → 0xe00002c1  kIOReturnNotPrivileged
IOPMSchedulePowerEvent(…, kIOPMAutoWakeOrPowerOn) → 0xe00002c1
```

There is no unprivileged path. `caffeinate` and `IOPMAssertion` **prevent** sleep; neither can
**end** it. So genuine scheduled wake needs a helper running as root, or it does not happen.

## What it would be

An `SMAppService.daemon` embedded in the app bundle, registered once with the user's approval and
visible to them afterwards in System Settings → Login Items.

**Its entire interface is one call:** *schedule a wake at this date*. It accepts a timestamp and
nothing else. No command, no path, no shell, no arbitrary arguments. A daemon that could be asked
to *run something* would be a different and much worse proposition.

```
app  ──  XPC: scheduleWake(at: Date)  ──▶  helper (root)
                                             ├── reject dates in the past
                                             ├── reject dates > 7 days out
                                             ├── cap at N scheduled events
                                             └── IOPMSchedulePowerEvent(date, "si.bupsy", kIOPMAutoWake)
```

## Threat model — the part that matters

bupsy runs AI agents that execute shell commands under the user's own credentials. Adding a root
daemon to that application means asking: **if an agent were induced to misbehave — by a prompt
injection in a web page it read, a poisoned repository, a malicious MCP server — what could it
reach through this helper?**

| Risk | Mitigation | Residual |
|---|---|---|
| Agent asks the helper to run a command | There is no such call. The interface takes a `Date`. | None, provided the interface never grows. **This is the invariant.** |
| Agent schedules endless wakes to drain a battery | Validate the date, cap total scheduled events, rate-limit. | Nuisance at worst. |
| Another local app talks to the helper | Code-signing requirement on the XPC connection; verify the peer's team ID and identifier. | Low. |
| Helper has a memory-safety bug reachable from the app | Swift, no C parsing, one input of one type. | Low, and the surface is a single date. |
| User forgets it exists | Visible in System Settings → Login Items; a settings row that says what it does and removes it in one click. | Acceptable. |

**The invariant to defend in review:** *the helper's interface accepts a date and returns a result.
If anyone ever adds a parameter that is a string the helper acts on, this design is void and the
threat model must be redone.* Put that at the top of the helper's source file.

## Why it is opt-in, and argued against by default

Tier 3 — a bot on a rented machine — already delivers lid-closed autonomy for about $13 a month,
with **zero local privilege**. For most people that is the better trade, and onboarding should say
so rather than nudging toward the root daemon because it is free.

The helper is worth offering to people who genuinely want a laptop-only setup and understand the
exchange. It is not worth making it the default, and it is not worth shipping to save $13.

## What it still needs

- [ ] Developer ID certificate — the daemon must be signed and notarized, and `SMAppService`
      refuses an unsigned one. **This blocks even testing it.**
- [ ] A second notarized binary in the build and release pipeline.
- [ ] XPC peer validation against our own team ID.
- [ ] A settings row: what it does, that it runs as root, and a one-click removal.
- [ ] Onboarding copy that presents the cloud machine *first* and this second.
- [ ] A security review of the helper on its own, separate from the app.

Until the certificate exists, the honest tiers are the free ones in PLAN.md §4 and the paid
machine. The UI should not mention a wake feature that cannot yet be installed.
