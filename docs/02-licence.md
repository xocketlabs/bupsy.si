# Licence: Business Source License 1.1

> Not legal advice. A licence is a legal instrument, and the parameter block below is the part
> that actually binds. The licensor is now named, which is what makes it enforceable at all; a
> lawyer should still read the Additional Use Grant before the first public build.

## What we chose, and what it means

bupsy.si is **source-available under BSL 1.1**, converting to **Apache-2.0 four years after each
version is published**.

| | |
|---|---|
| Read the source | ✅ |
| Use the app free, personally or inside your company | ✅ (Additional Use Grant) |
| Modify it, build it, self-host it for your own use | ✅ |
| Offer it to third parties as a product or hosted service | ❌ until the Change Date |
| Everything becomes Apache-2.0 | ✅ automatically, 4 years per version |

This is the licence used by Sentry, MariaDB and HashiCorp's Terraform. It is **not** an
open-source licence by the OSI definition, and we do not call it one.

## Why this instead of the alternatives

The original plan was Apache-2.0, positioned directly against OpenMausBot's open-core carve-out.
That was dropped deliberately: Apache-2.0 lets anyone rebrand and ship bupsy as their own product,
which is precisely what we could have done to them. The licence that prevents it is the licence
that prevents us claiming to be more open than they are, and that trade was made with open eyes.

Considered and rejected:

- **Apache-2.0 / MIT** — no protection against a rebranded fork competing with us.
- **Fully proprietary, source private** — strongest protection, but gives up readable source,
  outside contributions, and any credible claim to transparency for a tool that holds a user's
  agent credentials. For a local-first privacy product, "you can read exactly what it does" is
  worth real money.
- **A custom no-derivatives licence** — closest to a literal "don't modify it", but unusual,
  poorly understood, draws accusations of fake openness, makes contribution legally impossible,
  and needs bespoke drafting.

BSL keeps the source readable and the fork risk closed, and the four-year conversion means the
openness claim is deferred rather than abandoned.

## What this changes about how we talk

**Say:** "source-available", "free to use", "the source is public and becomes Apache-2.0 after four
years", "no backend, no account, no telemetry".

**Never say:** "open source", "FOSS", "libre". It is not, and saying so invites exactly the
criticism that hurts most — the audience most attracted to a local-first agent tool is the audience
most likely to check.

PLAN.md §1 lists **three** differentiators, not four: native rather than Electron, lid-closed
always-on, and MCP-native connectors. The openness argument was retired rather than weakened, which
is the honest move. Three real advantages beat four where one is contested.

## Consequences we have to live with

### A CLA is now necessary

Under BSL the Licensor must be able to relicense the work — that is what makes the Change Date
conversion to Apache-2.0 possible at all. Accepting a contribution with no agreement would leave
code we cannot relicense, breaking the promise above.

So contributions require a one-time CLA. `CONTRIBUTING.md` previously promised the opposite
("No CLA, and there will never be one"), written when the plan was Apache-2.0. That promise is
retracted before anyone relied on it, which is the only acceptable time to retract it.

### The clean-room rule gets sharper, not softer

Taking Apache-2.0 code from another project into a BSL work is possible but messy: the attribution
and NOTICE obligations survive, those files keep their own terms, and the boundary has to be
maintained forever. Do not do it casually. See `CONTRIBUTING.md` §2.

### Third-party dependencies are unaffected

GRDB, Sparkle, noVNC, libraries.dev packages and the rest keep their own licences, tracked in
[NOTICE](../NOTICE) and `third_party/`. BSL applies to *our* code.

### Vendor terms are a separate question entirely

Our licence governs our source. It has no bearing on Anthropic's or OpenAI's terms, which govern
how their binaries and credentials may be used. Both sets of rules apply at once, and
[docs/00-compliance-and-auth.md](00-compliance-and-auth.md) is the one that can get the product
shut down.

## Before the repo goes public

- [x] **Licensor set: Xocket Labs Inc., a Delaware corporation.** Both places in
      [LICENSE](../LICENSE), and the copyright line in [NOTICE](../NOTICE).
- [ ] Have a lawyer review the parameter block, especially the Additional Use Grant. Worth an
      hour of someone's time before the first public build: the grant decides what a competitor
      may do, and it is the clause that would actually be argued over.
- [ ] Decide whether the Change Date is four years (HashiCorp) or shorter (Sentry uses three).
      Shorter is a stronger good-faith signal; four is more protective.
- [ ] Add `CLA.md` and a bot or checklist to record agreement.
- [ ] Sweep all copy — README, site, store listing, social — for "open source". Replace with
      "source-available".
- [ ] Add the licence header or a `LICENSE` pointer to distributed builds; BSL requires the licence
      to be conspicuously displayed.
