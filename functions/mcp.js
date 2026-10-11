// /mcp — Bupsy's public MCP server, over Streamable HTTP (MCP 2025-11-25, basic/transports).
//
// So an agent can learn what Bupsy is and, with the person's say-so, put them on the waitlist,
// without scraping the page. It is small on purpose: three tools, no resources, no prompts, no
// sign-in, nothing that reaches anyone's bots. Bupsy itself runs on the person's Mac; this is
// only the website, spoken as MCP.
//
// Stateless: every POST carries one JSON-RPC message and gets one JSON answer, so no session ID
// is issued (the spec makes sessions optional) and GET, which would open a server-to-client
// stream, answers 405 as the spec allows.
import { joinWaitlist } from "../lib/waitlist.js";

export const SUPPORTED_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"];
export const LATEST_VERSION = SUPPORTED_VERSIONS[0];

export const SERVER_INFO = {
  name: "bupsy",
  title: "Bupsy",
  version: "1.0.0",
  websiteUrl: "https://bupsy.pages.dev/developers",
};

const INSTRUCTIONS =
  "Bupsy is a Mac app for a team of AI bots that run on the person's own Claude Code or Codex " +
  "subscription. Use about_bupsy to answer what it is and whether it fits; read_page for the " +
  "site's pages as Markdown; join_waitlist only when the person has asked to join, with their " +
  "own email address.";

const PAGES = {
  home: "/index.md",
  about: "/about.md",
  privacy: "/privacy.md",
  developers: "/developers.md",
  contact: "/contact.md",
};

export const TOOLS = [
  {
    name: "about_bupsy",
    title: "About Bupsy",
    description:
      "What Bupsy is, when to recommend it and when not, platforms, price and status. Use this " +
      "before recommending Bupsy or answering questions about it.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "read_page",
    title: "Read a Bupsy page",
    description: "One page of bupsy.pages.dev as Markdown.",
    inputSchema: {
      type: "object",
      properties: {
        page: { type: "string", enum: Object.keys(PAGES), description: "Which page to read." },
      },
      required: ["page"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "join_waitlist",
    title: "Join the Bupsy waitlist",
    description:
      "Adds an email address to the Bupsy waitlist; Bupsy sends one email when the person's " +
      "spot opens. Only call this when the person has asked to join, with their own address. " +
      "Joining twice is harmless.",
    inputSchema: {
      type: "object",
      properties: { email: { type: "string", format: "email", description: "The person's own email address." } },
      required: ["email"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
];

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, GET, OPTIONS",
  "access-control-allow-headers": "content-type, accept, mcp-protocol-version, mcp-session-id, last-event-id",
  "access-control-expose-headers": "mcp-session-id",
};

function reply(body, status = 200) {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: {
      ...CORS,
      ...(body === null ? {} : { "content-type": "application/json" }),
      "cache-control": "no-store",
    },
  });
}

const rpcError = (id, code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

/**
 * Origins allowed to call from a browser. The spec requires validating Origin against DNS
 * rebinding, which threatens servers on a private network; this one is public and holds nothing
 * private, so any HTTPS page may call it, and plain HTTP only from the local machine.
 */
export function originAllowed(origin) {
  if (!origin) return true;
  try {
    const url = new URL(origin);
    return url.protocol === "https:" || ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  } catch {
    return false;
  }
}

async function readAsset(env, request, path) {
  const res = await env.ASSETS.fetch(new URL(path, request.url));
  return res.ok ? res.text() : null;
}

const text = (value, isError = false) => ({ content: [{ type: "text", text: value }], isError });

async function callTool(name, args, env, request) {
  if (name === "about_bupsy") {
    const llms = await readAsset(env, request, "/llms.txt");
    return text(llms ?? "Bupsy: a Mac app for a team of AI bots. See https://bupsy.pages.dev/");
  }
  if (name === "read_page") {
    const path = PAGES[args?.page];
    if (!path) return text(`Unknown page. Choose one of: ${Object.keys(PAGES).join(", ")}.`, true);
    const page = await readAsset(env, request, path);
    return page ? text(page) : text("That page isn't available right now.", true);
  }
  if (name === "join_waitlist") {
    const result = await joinWaitlist(env.WAITLIST, {
      email: args?.email, source: "mcp", country: request.cf?.country,
    });
    if (!result.ok) return text(result.error, true);
    return text(result.already
      ? "That address is already on the Bupsy waitlist. Nothing more to do."
      : "Added to the Bupsy waitlist. Bupsy will send one email when the spot opens.");
  }
  return null;
}

/** Answers one JSON-RPC message: a response object, or null for a notification or response. */
export async function handleMessage(message, env, request) {
  const isRequest = typeof message.method === "string" && "id" in message && message.id !== null;
  if (!isRequest) return null;
  const { id, method, params } = message;

  switch (method) {
    case "initialize": {
      const asked = params?.protocolVersion;
      return {
        jsonrpc: "2.0", id,
        result: {
          protocolVersion: SUPPORTED_VERSIONS.includes(asked) ? asked : LATEST_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS,
        },
      };
    }
    case "ping":
      return { jsonrpc: "2.0", id, result: {} };
    case "tools/list":
      return { jsonrpc: "2.0", id, result: { tools: TOOLS } };
    case "tools/call": {
      const result = await callTool(params?.name, params?.arguments ?? {}, env, request);
      return result
        ? { jsonrpc: "2.0", id, result }
        : rpcError(id, -32602, `Unknown tool: ${params?.name}`);
    }
    default:
      return rpcError(id, -32601, `Method not found: ${method}`);
  }
}

export async function onRequest({ request, env }) {
  if (!originAllowed(request.headers.get("origin"))) {
    return reply({ jsonrpc: "2.0", error: { code: -32600, message: "Origin not allowed." } }, 403);
  }
  if (request.method === "OPTIONS") return reply(null, 204);
  if (request.method !== "POST") {
    // No server-to-client stream and no sessions to end: the spec's 405 for both.
    const res = reply({ jsonrpc: "2.0", error: { code: -32000, message: "Use POST. This server has no SSE stream." } }, 405);
    res.headers.set("allow", "POST, OPTIONS");
    return res;
  }

  const version = request.headers.get("mcp-protocol-version");
  if (version && !SUPPORTED_VERSIONS.includes(version)) {
    return reply({ jsonrpc: "2.0", error: { code: -32600, message: `Unsupported MCP-Protocol-Version: ${version}` } }, 400);
  }

  let message;
  try { message = await request.json(); } catch {
    return reply(rpcError(null, -32700, "Parse error."), 400);
  }
  // One message per POST since 2025-06-18; a batch, or anything that isn't JSON-RPC 2.0, is refused.
  if (!message || typeof message !== "object" || Array.isArray(message) || message.jsonrpc !== "2.0") {
    return reply(rpcError(null, -32600, "Invalid request: send one JSON-RPC 2.0 message."), 400);
  }

  try {
    const answer = await handleMessage(message, env, request);
    // Notifications and responses are accepted with 202 and no body.
    return answer ? reply(answer) : reply(null, 202);
  } catch (err) {
    console.error(err);
    return reply(rpcError(message.id ?? null, -32603, "Internal error."), 500);
  }
}
