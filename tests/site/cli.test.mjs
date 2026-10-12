import { test } from "node:test";
import assert from "node:assert/strict";
import { run, parseArgs, INSTALL_HINT } from "../../cli/bin/bupsy.js";

/** A fake fetch that records calls and answers from a table. */
function harness(answers) {
  const calls = [], out = [], err = [];
  const io = {
    calls, printed: out, complained: err,
    fetch: async (url, init = {}) => {
      calls.push({ url, method: init.method || "GET", body: init.body && JSON.parse(init.body) });
      const path = new URL(url).pathname;
      const [status, body, type] = answers[path] ?? [404, "missing", "text/plain"];
      return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers: { "content-type": type || "application/json" } });
    },
    out: { write: (s) => out.push(s) },
    err: { write: (s) => err.push(s) },
  };
  return io;
}

test("parseArgs reads words, --flag value and --flag=value", () => {
  assert.deepEqual(parseArgs(["join", "a@b.co", "--source=x", "--json"]), { words: ["join", "a@b.co"], flags: { source: "x", json: true } });
  assert.deepEqual(parseArgs(["contact", "--email", "a@b.co"]).flags, { email: "a@b.co" });
  // A switch never swallows the word after it.
  assert.deepEqual(parseArgs(["download", "--updates", "a@b.co"]), { words: ["download", "a@b.co"], flags: { updates: true } });
});

const DMG = "https://github.com/xocketlabs/bupsy.si/releases/latest/download/Bupsy.dmg";

test("download posts the address from the cli, without the monthly email unless asked", async () => {
  const io = harness({ "/api/download": [200, { ok: true, url: DMG, already: false }] });
  assert.equal(await run(["download", "a@b.co"], io), 0);
  assert.deepEqual(io.calls[0], { url: "https://bupsy.pages.dev/api/download", method: "POST", body: { email: "a@b.co", updates: false, source: "cli" } });
  const printed = io.printed.join("");
  assert.ok(printed.includes(DMG));
  assert.ok(printed.includes(INSTALL_HINT));
  assert.match(INSTALL_HINT, /Privacy & Security, Open Anyway/);
  assert.doesNotMatch(printed, /one email a month/);
});

test("download --updates asks for the monthly email", async () => {
  const io = harness({ "/api/download": [200, { ok: true, url: DMG, already: true }] });
  assert.equal(await run(["download", "a@b.co", "--updates"], io), 0);
  assert.equal(await run(["download", "--updates", "a@b.co"], io), 0);
  assert.equal(io.calls[0].body.updates, true);
  assert.deepEqual(io.calls[1].body, { email: "a@b.co", updates: true, source: "cli" });
  assert.match(io.printed.join(""), /one email a month/);
});

test("download --json prints the API's JSON, and an error exits 1", async () => {
  const ok = harness({ "/api/download": [200, { ok: true, url: DMG, already: false }] });
  assert.equal(await run(["download", "a@b.co", "--json"], ok), 0);
  assert.deepEqual(JSON.parse(ok.printed.join("")), { ok: true, url: DMG, already: false });
  const bad = harness({ "/api/download": [400, { code: "invalid_email", detail: "That doesn't look like an email address.", resolution: "Send the person's email address." }] });
  assert.equal(await run(["download", "nope"], bad), 1);
  assert.match(bad.complained.join(""), /doesn't look like an email/);
});

test("join posts the address and reports a repeat", async () => {
  const io = harness({ "/api/waitlist": [200, { ok: true, already: true }] });
  assert.equal(await run(["join", "a@b.co"], io), 0);
  assert.deepEqual(io.calls[0], { url: "https://bupsy.pages.dev/api/waitlist", method: "POST", body: { email: "a@b.co", source: "cli" } });
  assert.match(io.printed.join(""), /Already on Bupsy's list[\s\S]*bupsy download/);
});

test("an API error prints its detail and resolution and exits 1", async () => {
  const io = harness({ "/api/waitlist": [400, { code: "invalid_email", detail: "That doesn't look like an email address.", resolution: "Send the person's email address." }] });
  assert.equal(await run(["join", "nope"], io), 1);
  assert.match(io.complained.join(""), /doesn't look like an email[\s\S]*Send the person's email/);
});

test("about, page and openapi read the site's own files", async () => {
  const io = harness({ "/llms.txt": [200, "# Bupsy", "text/plain"], "/developers.md": [200, "# Bupsy for developers", "text/markdown"], "/openapi.json": [200, { openapi: "3.1.0" }] });
  assert.equal(await run(["about"], io), 0);
  assert.equal(await run(["page", "developers"], io), 0);
  assert.equal(await run(["openapi"], io), 0);
  assert.match(io.printed.join(""), /# Bupsy[\s\S]*developers[\s\S]*3\.1\.0/);
});

test("wrong usage exits 2 without calling the network", async () => {
  const io = harness({});
  assert.equal(await run(["page", "secrets"], io), 2);
  assert.equal(await run(["contact", "--email", "a@b.co"], io), 2);
  assert.equal(await run(["download"], io), 2);
  assert.equal(await run(["download", "--updates"], io), 2);
  assert.equal(await run(["frobnicate"], io), 2);
  assert.equal(await run([], io), 2);
  assert.equal(await run(["--help"], io), 0);
  assert.equal(io.calls.length, 0);
});

test("mcp prints the endpoint and a JSON config", async () => {
  const io = harness({});
  assert.equal(await run(["mcp", "--json"], io), 0);
  assert.deepEqual(JSON.parse(io.printed.join("")), { mcpServers: { bupsy: { type: "http", url: "https://bupsy.pages.dev/mcp" } } });
});
