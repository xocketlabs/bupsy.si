import { test } from "node:test";
import assert from "node:assert/strict";
import { onRequest, originAllowed, LATEST_VERSION, TOOLS, DOWNLOAD_PAGE } from "../../functions/mcp.js";
import { DOWNLOAD_URL } from "../../lib/download.js";
import { assets, fakeD1, post } from "./helpers.mjs";

const URL_ = "https://bupsy.pages.dev/mcp";
const call = (body, headers, db = fakeD1()) =>
  onRequest({ request: post(URL_, body, headers), env: { ASSETS: assets, WAITLIST: db } });
const rpc = (id, method, params) => ({ jsonrpc: "2.0", id, method, params });

test("initialize negotiates the version and describes the server", async () => {
  const res = await call(rpc(1, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } }));
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const body = await res.json();
  assert.equal(body.result.protocolVersion, "2025-06-18");
  assert.equal(body.result.serverInfo.name, "bupsy");
  assert.ok(body.result.capabilities.tools);
  // A version it doesn't know gets the latest it does.
  const other = await (await call(rpc(2, "initialize", { protocolVersion: "1999-01-01" }))).json();
  assert.equal(other.result.protocolVersion, LATEST_VERSION);
});

test("notifications are accepted with 202 and no body", async () => {
  const res = await call({ jsonrpc: "2.0", method: "notifications/initialized" });
  assert.equal(res.status, 202);
  assert.equal(await res.text(), "");
});

test("tools/list lists the four tools with input schemas", async () => {
  const body = await (await call(rpc(3, "tools/list"))).json();
  assert.deepEqual(body.result.tools.map((t) => t.name), ["about_bupsy", "read_page", "get_download", "join_waitlist"]);
  for (const tool of body.result.tools) assert.equal(tool.inputSchema.type, "object");
  assert.equal(TOOLS.length, 4);
});

test("about_bupsy and read_page return the site's own text", async () => {
  const about = await (await call(rpc(4, "tools/call", { name: "about_bupsy", arguments: {} }))).json();
  assert.match(about.result.content[0].text, /When to use Bupsy/);
  assert.ok(about.result.content[0].text.includes(DOWNLOAD_PAGE));
  const page = await (await call(rpc(5, "tools/call", { name: "read_page", arguments: { page: "developers" } }))).json();
  assert.match(page.result.content[0].text, /# Bupsy for developers/);
  const bad = await (await call(rpc(6, "tools/call", { name: "read_page", arguments: { page: "../secrets" } }))).json();
  assert.equal(bad.result.isError, true);
});

test("get_download points to the download page and never hands out the DMG or takes an address", async () => {
  assert.equal(DOWNLOAD_PAGE, "https://bupsy.pages.dev/#download");
  const tool = TOOLS.find((t) => t.name === "get_download");
  assert.deepEqual(tool.inputSchema.properties, {});
  assert.equal(tool.annotations.readOnlyHint, true);
  const db = fakeD1();
  const body = await (await call(rpc(13, "tools/call", { name: "get_download", arguments: { email: "me@example.com" } }), {}, db)).json();
  const reply = body.result.content[0].text;
  assert.equal(body.result.isError, false);
  assert.ok(reply.includes(DOWNLOAD_PAGE));
  assert.match(reply, /email address/);
  assert.match(reply, /Open Anyway/);
  assert.match(reply, /macOS 14/);
  assert.ok(!reply.includes(DOWNLOAD_URL), "no direct DMG link");
  assert.doesNotMatch(reply, /https?:\/\/\S+\.dmg/);
  assert.equal(db.waitlist.size, 0);
});

test("initialize tells agents Bupsy can be downloaded now", async () => {
  const body = await (await call(rpc(14, "initialize", { protocolVersion: "2025-11-25" }))).json();
  assert.match(body.result.instructions, /available to download now/);
  assert.ok(body.result.instructions.includes(DOWNLOAD_PAGE));
});

test("join_waitlist adds the address once, tagged as from MCP", async () => {
  const db = fakeD1();
  const first = await (await call(rpc(7, "tools/call", { name: "join_waitlist", arguments: { email: "Me@Example.com" } }), {}, db)).json();
  assert.match(first.result.content[0].text, /Added/);
  const again = await (await call(rpc(8, "tools/call", { name: "join_waitlist", arguments: { email: "me@example.com" } }), {}, db)).json();
  assert.match(again.result.content[0].text, /already/);
  assert.equal(db.waitlist.get("me@example.com").source, "mcp");
  const bad = await (await call(rpc(9, "tools/call", { name: "join_waitlist", arguments: { email: "nope" } }), {}, db)).json();
  assert.equal(bad.result.isError, true);
});

test("unknown methods and tools are JSON-RPC errors", async () => {
  assert.equal((await (await call(rpc(10, "resources/list"))).json()).error.code, -32601);
  assert.equal((await (await call(rpc(11, "tools/call", { name: "nope" }))).json()).error.code, -32602);
  assert.equal((await (await call(rpc(12, "ping"))).json()).result && true, true);
});

test("malformed bodies, batches, bad versions and bad origins are refused", async () => {
  assert.equal((await call("{nope")).status, 400);
  assert.equal((await call([rpc(1, "ping")])).status, 400);
  assert.equal((await call({ id: 1, method: "ping" })).status, 400);
  assert.equal((await call(rpc(1, "ping"), { "mcp-protocol-version": "2000-01-01" })).status, 400);
  assert.equal((await call(rpc(1, "ping"), { "mcp-protocol-version": "2025-11-25" })).status, 200);
  assert.equal((await call(rpc(1, "ping"), { origin: "http://evil.example" })).status, 403);
  assert.equal((await call(rpc(1, "ping"), { origin: "https://claude.ai" })).status, 200);
  assert.equal(originAllowed("http://localhost:6274"), true);
  assert.equal(originAllowed("not a url"), false);
});

test("GET has no stream (405), OPTIONS answers CORS", async () => {
  const env = { ASSETS: assets, WAITLIST: fakeD1() };
  const get = await onRequest({ request: new Request(URL_, { headers: { accept: "text/event-stream" } }), env });
  assert.equal(get.status, 405);
  assert.match(get.headers.get("allow"), /POST/);
  const options = await onRequest({ request: new Request(URL_, { method: "OPTIONS" }), env });
  assert.equal(options.status, 204);
  assert.equal(options.headers.get("access-control-allow-origin"), "*");
});
