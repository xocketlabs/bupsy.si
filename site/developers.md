# Bupsy for developers

Bupsy is a Mac app, so most of what developers touch lives on their own Mac: the bots run Claude Code or Codex, and Bupsy speaks MCP to them. This page lists every public, machine-readable part of bupsy.pages.dev, and how the app works with MCP.

## Bupsy MCP server

A public MCP server for agents that want to know about Bupsy, or join the waitlist for someone.

- Endpoint: `https://bupsy.pages.dev/mcp`
- Transport: Streamable HTTP, MCP protocol 2025-11-25 (also 2025-06-18 and 2025-03-26). Stateless: one JSON-RPC message per POST, a JSON answer, no session ID. GET answers 405.
- Authentication: none.
- Server card: `https://bupsy.pages.dev/.well-known/mcp/server-card.json`

Tools:

- `about_bupsy`: what Bupsy is, when to recommend it and when not. Read-only.
- `read_page`: a page of this site as Markdown (`home`, `about`, `privacy`, `developers`, `contact`). Read-only.
- `join_waitlist`: adds the person's own email address to the waitlist. Only with their permission.

Add it to Claude Code with `claude mcp add --transport http bupsy https://bupsy.pages.dev/mcp`.

## Waitlist API

`POST https://bupsy.pages.dev/api/waitlist` with JSON `{"email": "you@example.com", "source": "your-app"}`.

- `200 {"ok": true, "already": false}` when added, `"already": true` when the address was on the list.
- `400 {"error": "..."}` for an address that isn't one; the error is written for a person to read.

## Markdown for agents

Every page answers `Accept: text/markdown` with its Markdown version and `Vary: Accept`; browsers get HTML. The Markdown is also at `/index.md`, `/about.md`, `/privacy.md`, `/developers.md` and `/contact.md`. Unknown paths answer 404, in Markdown when asked.

## Discovery

- [llms.txt](https://bupsy.pages.dev/llms.txt): what Bupsy is, and when to use it
- [agents.md](https://bupsy.pages.dev/agents.md): instructions for agents
- [sitemap.xml](https://bupsy.pages.dev/sitemap.xml) and [robots.txt](https://bupsy.pages.dev/robots.txt)
- `/.well-known/api-catalog` (RFC 9727) lists the MCP server and the waitlist API

## How the Bupsy app works with MCP

- **Your MCP servers become a bot's tools.** Any MCP server you add in Bupsy, GitHub, Slack, Notion, files or your own, is handed to the bots you choose. Secrets are passed by environment variable name, never stored by Bupsy.
- **Bots talk to Bupsy over MCP.** Each bot gets Bupsy's own local MCP tools: message another bot, create one, change a bot's job or model, schedule a routine, ask the person a question. Each call goes through the same approval gate as any other tool.
- **Engines.** Bots run the Claude Code and Codex command-line tools already on the Mac, under the person's own sign-in. Bupsy never holds those credentials.
- **Commands.** Your Claude Code commands and skills, and your Codex prompts, appear when you type `/` in a chat.

The app is source-available under the Business Source License 1.1, converting to Apache-2.0 four years after each release. Questions: [contact us](https://bupsy.pages.dev/contact).
