# Licence: PolyForm Shield 1.0.0

> Not legal advice. [LICENSE](../LICENSE) is the text that binds; this page explains it. Have a
> lawyer read it before relying on it in a dispute.

## What we chose, and what it means

bupsy.si is **source-available under the [PolyForm Shield License 1.0.0](../LICENSE)**, licensed by
Xocket Labs Inc., a Delaware corporation.

| | |
|---|---|
| Read the source | ✅ |
| Use the app free, personally or at work, in any company | ✅ |
| Change it, build it, run it on machines you control | ✅ |
| Share copies, with or without your changes | ✅ as long as it isn't a competing product |
| Make a product that competes with Bupsy (a fork, clone, rebrand or hosted version, paid or free) | ❌ never |
| Expires, or turns into an open-source licence later | ❌ no |

The licence's own test for competing: goods and services compete even across different interfaces,
platforms and languages, and even when free; "if you market a product as a practical substitute for
the software or another product, it definitely competes."

It is **not** an open-source licence by the OSI definition, and we do not call it one.

## History: BSL 1.1 until 0.2.0

Bupsy 0.2.0 and earlier were published under the **Business Source License 1.1**, which forbade
offering the work to third parties as a product or service and converted each version to
Apache-2.0 four years after it was published. Licences already granted cannot be taken back, so
**those versions keep those terms**, including their conversion (0.2.0's code becomes Apache-2.0 in
October 2030). Everything after 0.2.0 is PolyForm Shield.

We changed because BSL's conversion is compulsory: the licence requires a Change Date of at most four
years. We wanted the protection against competing products to last, and PolyForm Shield is the
standard, lawyer-drafted licence that does exactly that, while keeping the app free for everyone to
use, including at work.

## Why this instead of the alternatives

- **Apache-2.0 / MIT**: no protection against a rebranded fork competing with us.
- **BSL 1.1**: good protection, but it ends after at most four years per version.
- **PolyForm Noncommercial**: would forbid using the app for paid work, which is most of our users.
- **PolyForm Strict, or a custom no-derivatives licence**: blocks changes and contributions too.
- **Fully proprietary, source private**: gives up readable source and outside contributions, for a
  tool that runs agents on people's machines and where "you can read exactly what it does" matters.

One trade-off we accepted: Shield lets someone reuse a piece of our code inside an unrelated,
non-competing product. BSL forbade that until its Change Date. Clones and competitors are blocked by
both.

## What this changes about how we talk

**Say:** "source-available", "free to use", "the source is public", "no backend, no account, no
telemetry".

**Never say:** "open source", "FOSS", "libre". It is not, and saying so invites exactly the
criticism that hurts most: the audience drawn to a local-first agent tool is the one most likely to
check.

## Consequences we live with

### A CLA

The Licensor must be able to license every line on the project's terms, today and if they change.
Contributions therefore need the one-time [CLA](../CLA.md), agreed by ticking its box in a pull
request.

### The clean-room rule

Taking Apache-2.0 or MIT code from another project into this one is possible but messy: the
attribution and NOTICE obligations survive, those files keep their own terms, and the boundary has
to be maintained forever. Do not do it casually. See `CONTRIBUTING.md` §2.

### Third-party dependencies are unaffected

GRDB.swift and Sparkle keep their own licences, tracked in [NOTICE](../NOTICE) and `third_party/`
and shipped inside the app. Our licence applies to *our* code.

### Vendor terms are a separate question

Our licence governs our source. It has no bearing on Anthropic's or OpenAI's terms, which govern how
their binaries and credentials may be used. Both apply at once, and
[docs/00-compliance-and-auth.md](00-compliance-and-auth.md) is the one that could get the product shut
down.
