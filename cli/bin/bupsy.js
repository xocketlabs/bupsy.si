#!/usr/bin/env node
// bupsy: the website's API from a terminal, for people and for agents scripting it.
//
// Every command is one call to bupsy.pages.dev (see /openapi.json). `--json` prints the API's own
// JSON. Exit codes: 0 done, 1 the API said no (its `detail` and `resolution` go to stderr),
// 2 the command was used wrongly.

export const BASE = "https://bupsy.pages.dev";
export const PAGES = ["home", "about", "privacy", "developers", "contact"];

export const HELP = `bupsy: Bupsy from the command line (https://bupsy.pages.dev)

Usage:
  bupsy about                         What Bupsy is, and when to use it
  bupsy page <${PAGES.join("|")}>     A page of the site as Markdown
  bupsy join <email> [--source name]  Join the waitlist (your own address)
  bupsy contact --email <e> --message <text> [--name <n>]
                                      Send a message to the people who make Bupsy
  bupsy mcp                           How to add Bupsy's MCP server to your agent
  bupsy openapi                       The API's OpenAPI 3.1 document

Options:
  --json        Print the API's JSON
  --base <url>  Another server (for testing)
  -h, --help    This help`;

/** Splits argv into positional words and --flags. */
export function parseArgs(argv) {
  const words = [], flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") flags.help = true;
    else if (arg === "--json") flags.json = true;
    else if (arg.startsWith("--")) {
      const [key, inline] = arg.slice(2).split("=", 2);
      flags[key] = inline ?? argv[++i];
    } else words.push(arg);
  }
  return { words, flags };
}

/**
 * Runs one command. `io` carries fetch and the output streams, so tests can run it without a
 * network. Resolves to the exit code.
 */
export async function run(argv, io = { fetch: globalThis.fetch, out: process.stdout, err: process.stderr }) {
  const { words, flags } = parseArgs(argv);
  const base = (flags.base || BASE).replace(/\/+$/, "");
  const say = (text) => io.out.write(text.endsWith("\n") ? text : text + "\n");
  const complain = (text) => io.err.write(text.endsWith("\n") ? text : text + "\n");
  const [command, arg] = words;

  if (flags.help || !command) { say(HELP); return command || flags.help ? 0 : 2; }

  async function get(path) {
    const res = await io.fetch(base + path, { headers: { accept: "text/markdown, text/plain, application/json" } });
    if (!res.ok) { complain(`${path}: HTTP ${res.status}`); return null; }
    return res.text();
  }
  async function post(path, body) {
    const res = await io.fetch(base + path, {
      method: "POST", headers: { "content-type": "application/json", accept: "application/json" }, body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (flags.json) say(JSON.stringify(data));
    if (!res.ok) {
      complain(`${data.detail || data.error || `HTTP ${res.status}`}${data.resolution ? `\n${data.resolution}` : ""}`);
      return null;
    }
    return data;
  }

  switch (command) {
    case "about": {
      const text = await get("/llms.txt");
      if (text === null) return 1;
      say(text); return 0;
    }
    case "page": {
      if (!PAGES.includes(arg)) { complain(`Choose a page: ${PAGES.join(", ")}`); return 2; }
      const text = await get(arg === "home" ? "/index.md" : `/${arg}.md`);
      if (text === null) return 1;
      say(text); return 0;
    }
    case "join": {
      if (!arg) { complain("Usage: bupsy join <email> [--source name]"); return 2; }
      const data = await post("/api/waitlist", { email: arg, source: flags.source || "cli" });
      if (!data) return 1;
      if (!flags.json) say(data.already ? "Already on the Bupsy waitlist." : "Added to the Bupsy waitlist. One email when your spot opens.");
      return 0;
    }
    case "contact": {
      if (!flags.email || !flags.message) { complain("Usage: bupsy contact --email <e> --message <text> [--name <n>]"); return 2; }
      const data = await post("/api/contact", { email: flags.email, message: flags.message, name: flags.name });
      if (!data) return 1;
      if (!flags.json) say("Sent. The Bupsy team answers by email.");
      return 0;
    }
    case "mcp": {
      const url = `${base}/mcp`;
      if (flags.json) say(JSON.stringify({ mcpServers: { bupsy: { type: "http", url } } }));
      else say(`Bupsy's MCP server: ${url} (Streamable HTTP, no sign-in)\n\nClaude Code:\n  claude mcp add --transport http bupsy ${url}\n\nOther clients (mcpServers JSON):\n  ${JSON.stringify({ bupsy: { type: "http", url } })}`);
      return 0;
    }
    case "openapi": {
      const text = await get("/openapi.json");
      if (text === null) return 1;
      say(text); return 0;
    }
    default:
      complain(`Unknown command: ${command}\n\n${HELP}`);
      return 2;
  }
}

// Run when executed, not when imported by the tests.
if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("/bupsy")) {
  run(process.argv.slice(2)).then((code) => { process.exitCode = code; });
}
