# Security

Bupsy runs AI agents on people's own Macs, with their own accounts. A security problem here can
mean someone else's files, commands or credentials, so we take reports seriously and fix them first.

## Reporting a vulnerability

Please report privately, not in a public issue:

- **GitHub:** [Report a vulnerability](https://github.com/xocketlabs/bupsy.si/security/advisories/new)
  (private advisory, visible only to you and the maintainers), or
- **Email:** remotevansh@gmail.com, with "Security" in the subject.

Include what you found, how to reproduce it, and what an attacker could do with it. We will
acknowledge the report, keep you updated, and credit you in the release notes unless you would
rather not be named. Please give us a reasonable time to ship a fix before disclosing publicly.

## What we especially want to hear about

These are the promises the app makes; anything that breaks one is a vulnerability:

- **Bupsy never reads or stores a vendor credential** (Claude Code, Codex sign-ins). See
  [docs/00-compliance-and-auth.md](docs/00-compliance-and-auth.md).
- **The approval gate cannot be bypassed.** A bot on "ask" or "trusted" must not run a command,
  edit a file or call a connector without the person's say-so, including through Bupsy's own MCP
  tools, bot-to-bot messages or routines.
- **Remote access stays private.** Use from other devices works only over the person's Tailscale
  network, only for paired devices, and never exposes anything to the public internet.
- **A bot kept to "This Mac only"** is invisible to every other device.
- **The website and its MCP server** (bupsy.pages.dev) keep only what the privacy page says.

## Supported versions

Only the latest release gets security fixes. Bupsy is early, and updating is the fix.
