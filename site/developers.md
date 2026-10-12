# Bupsy for developers

Bupsy is a Mac app, so most of what developers touch lives on their own Mac: the bots run Claude Code or Codex, and Bupsy speaks MCP to them. This page lists every public, machine-readable part of bupsy.pages.dev, and how the app works with MCP.

## Bupsy MCP server

A public MCP server for agents that want to know about Bupsy, or help someone get it.

- Endpoint: `https://bupsy.pages.dev/mcp`
- Transport: Streamable HTTP, MCP protocol 2025-11-25 (also 2025-06-18 and 2025-03-26). Stateless: one JSON-RPC message per POST, a JSON answer, no session ID. GET answers 405.
- Authentication: none.
- Server card: `https://bupsy.pages.dev/.well-known/mcp/server-card.json`

Tools:

- `about_bupsy`: what Bupsy is, when to recommend it and when not. Read-only.
- `read_page`: a page of this site as Markdown (`home`, `about`, `privacy`, `developers`, `contact`). Read-only.
- `get_download`: where and how to download Bupsy. It points to the download page, which asks for the person's own email address; it takes no address and downloads nothing. Read-only.
- `join_waitlist`: adds the person's own email address to the older "keep me posted" list, without a download. Kept for agents that already use it. Only with their permission.

Add it to Claude Code with `claude mcp add --transport http bupsy https://bupsy.pages.dev/mcp`.

## Bupsy API reference

The whole API is described in an OpenAPI 3.1 document: [openapi.json](https://bupsy.pages.dev/openapi.json). Every operation has an `operationId`, typed request and response schemas and a description, so it works as-is for function calling. No authentication.

- `startDownload`: `POST /api/download`
- `joinWaitlist`: `POST /api/waitlist` (older, still supported)
- `sendContactMessage`: `POST /api/contact`
- `callMcp`: `POST /mcp` (MCP JSON-RPC)

## Download API

`POST https://bupsy.pages.dev/api/download` with JSON `{"email": "you@example.com", "updates": false, "source": "your-app"}`.

- `200 {"ok": true, "url": "https://github.com/xocketlabs/bupsy.si/releases/latest/download/Bupsy.dmg", "already": false}`. `url` is always the newest Bupsy.dmg; `already` is true when the address had downloaded or joined the list before.
- `updates` is optional and false unless sent. `true` means the person asked for one email a month about what's new; without it Bupsy sends them nothing. A later download can turn it on, never off.
- No account and no verification. Only with the person's own address and their permission; usually it's simpler to send them to [the download page](https://bupsy.pages.dev/#download).
- Builds may not be Apple-signed yet, so the first open needs System Settings, Privacy & Security, Open Anyway. The [source is on GitHub](https://github.com/xocketlabs/bupsy.si) for anyone who'd rather build it.

## Waitlist API

The older "keep me posted" list, still supported so existing agents and scripts keep working. For the app itself, use the download API above.

`POST https://bupsy.pages.dev/api/waitlist` with JSON `{"email": "you@example.com", "source": "your-app"}`.

- `200 {"ok": true, "already": false}` when added, `"already": true` when the address was on the list.
- It doesn't start a download or sign anyone up for the monthly email.
- Only with the person's own address and their permission.

## Contact API

`POST https://bupsy.pages.dev/api/contact` with JSON `{"name": "Sam", "email": "sam@example.com", "message": "..."}`. `200 {"ok": true}`; we answer by email.

## Errors

Errors are RFC 9457 problem details (`application/problem+json`): `type`, `title`, `status`, `detail` for people, a stable `code` to branch on, and a `resolution` saying what to do next. Unknown `/api/` addresses answer a JSON 404.

- `invalid_json`, `invalid_body`: the body isn't a JSON object.
- `invalid_email`: the `email` field isn't an address.
- `empty_message`, `message_too_long`: the contact `message` is missing or over 4,000 characters.
- `not_found`, `method_not_allowed`: no such endpoint, or not POST.
- `unavailable`, `server_error`: try again shortly.

## Markdown for agents

Every page answers `Accept: text/markdown` with its Markdown version and `Vary: Accept`; browsers get HTML. The Markdown is also at `/index.md`, `/about.md`, `/privacy.md`, `/developers.md` and `/contact.md`. Unknown paths answer 404, in Markdown when asked.

## Discovery

- [llms.txt](https://bupsy.pages.dev/llms.txt): what Bupsy is, and when to use it
- [agents.md](https://bupsy.pages.dev/agents.md): instructions for agents
- [sitemap.xml](https://bupsy.pages.dev/sitemap.xml) and [robots.txt](https://bupsy.pages.dev/robots.txt)
- [openapi.json](https://bupsy.pages.dev/openapi.json): the OpenAPI 3.1 spec
- `/.well-known/api-catalog` (RFC 9727) lists the MCP server, the download API, the waitlist API and the contact API

## How the Bupsy app works with MCP

- **Your MCP servers become a bot's tools.** Any MCP server you add in Bupsy, GitHub, Slack, Notion, files or your own, is handed to the bots you choose. Secrets are passed by environment variable name, never stored by Bupsy.
- **Bots talk to Bupsy over MCP.** Each bot gets Bupsy's own local MCP tools: message another bot, create one, change a bot's job or model, schedule a routine, ask the person a question. Each call goes through the same approval gate as any other tool.
- **Engines.** Bots run the Claude Code and Codex command-line tools already on the Mac, under the person's own sign-in. Bupsy never holds those credentials.
- **Commands.** Your Claude Code commands and skills, and your Codex prompts, appear when you type `/` in a chat.

The app is source-available under the Business Source License 1.1, converting to Apache-2.0 four years after each release. Questions: [contact us](https://bupsy.pages.dev/contact).
