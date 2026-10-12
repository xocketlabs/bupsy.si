# Bupsy

> Your AI already has a subscription. Give it a job.

Bupsy is a Mac app where a little team of AI bots lives. Each bot runs **Claude Code** or **Codex** under your own sign-in, on the plan you already pay for. No new account, no credits, no server of ours in the middle.

Status: available now for Mac (macOS 14 or later, Apple silicon and Intel). Free. [Download Bupsy](https://bupsy.si/#download) for your email address.

## What it does

- **A roster, not a chat box.** Each bot has its own job, its own face, and its own sense of when to ask you first.
- **The face is the status.** Ready, working, needs you, done, asleep or stuck, at a glance.
- **Asks before it acts.** Anything beyond reading stops and asks. Shell commands are never auto-allowed. Four trust levels, from "ask me everything" to "never ask".
- **Routines and goals.** "Brief me every weekday at 7." "Keep my inbox under a day old." Routines run on a schedule, even with the app closed; goals check themselves and act only when something is off.
- **Bots that hand work to each other.** Group chats with @mentions. A lead bot can make teammates, give them jobs, switch their model, schedule their routines and check their work, within the trust you give it.
- **Your commands come too.** Type `/` for your Claude Code commands and skills, your Codex prompts, or Bupsy's own. Carry on any Claude Code conversation from VS Code or the terminal as a bot.
- **Long chats stay cheap.** The bot writes itself hand-off notes and carries on in a fresh chat, so each message costs a fraction.
- **Talk to it.** Speak to a bot and hear it answer, with your Mac's own voices.
- **Connect any tool.** Gmail, Notion, Linear, any MCP server or API, through Executor, which keeps the keys.
- **See what it changed.** Every file a bot wrote, every action it took, and what it would have cost.

## Privacy and trust

Bupsy runs the tools. It never holds the keys. You sign in to your CLI yourself; there is no Bupsy account and no server of ours. Conversations are files on your own disk. No telemetry. See [Privacy](https://bupsy.si/privacy).

## Platforms

| Platform | Status |
|---|---|
| Mac (macOS 14+) | Available now. The full app. |
| Phone and other Macs | With the Mac app: in the browser over Tailscale. Chat, approve, stop, move bots between Macs. |
| iPhone app | In development |
| Windows and Linux | In development |

## Get started

1. Download Bupsy at <https://bupsy.si/#download>. It's free; the page asks for your email address. Tick the box if you'd like one email a month about what's new.
2. Open Bupsy.dmg and drag Bupsy into Applications. The first time, macOS may refuse to open it because the build isn't Apple-signed yet: open System Settings, Privacy & Security, and click Open Anyway.
3. Install Claude Code or Codex and sign in once.
4. Open Bupsy, click +, and your new bot asks what it's for.

The source is on GitHub, if you'd rather build it yourself: <https://github.com/xocketlabs/bupsy.si>.

Made by Xocket Labs Inc. Not affiliated with Anthropic or OpenAI. More: [About](https://bupsy.si/about), [Developers](https://bupsy.si/developers), [Contact](https://bupsy.si/contact), [llms.txt](https://bupsy.si/llms.txt). MCP server: https://bupsy.si/mcp
