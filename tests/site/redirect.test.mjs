import { test } from "node:test";
import assert from "node:assert/strict";
import { onRequest, redirectTo } from "../../functions/_middleware.js";
import { assets } from "./helpers.mjs";

const served = new Response("served", { status: 200, headers: { "content-type": "text/plain" } });
const run = (url, init = {}) =>
  onRequest({ request: new Request(url, init), env: { ASSETS: assets }, next: async () => served.clone() });

test("GETs on the old Pages address and on www move to bupsy.si, same path and query", async () => {
  for (const host of ["bupsy.pages.dev", "www.bupsy.si"]) {
    for (const [path, to] of [["/", "/"], ["/about", "/about"], ["/llms.txt", "/llms.txt"], ["/?ref=x", "/?ref=x"],
      ["/.well-known/mcp/server-card.json", "/.well-known/mcp/server-card.json"]]) {
      const res = await run(`https://${host}${path}`);
      assert.equal(res.status, 301, host + path);
      assert.equal(res.headers.get("location"), "https://bupsy.si" + to, host + path);
    }
    const head = await run(`https://${host}/about`, { method: "HEAD" });
    assert.equal(head.status, 301);
  }
});

test("the API and the MCP server keep answering on the old addresses, never with a redirect", async () => {
  for (const host of ["bupsy.pages.dev", "www.bupsy.si"]) {
    for (const path of ["/api/download", "/api/waitlist", "/api/contact", "/mcp"]) {
      const res = await run(`https://${host}${path}`, {
        method: "POST", headers: { "content-type": "application/json" }, body: "{}",
      });
      assert.equal(res.status, 200, host + path);
      assert.equal(await res.text(), "served");
    }
    // A GET to the MCP endpoint or the API is not a page either.
    assert.equal(redirectTo(new Request(`https://${host}/mcp`)), null);
    assert.equal(redirectTo(new Request(`https://${host}/api/download`)), null);
  }
});

test("no redirect on bupsy.si itself, or on deploy previews", async () => {
  for (const url of ["https://bupsy.si/", "https://bupsy.si/about", "https://4f2a9c1e.bupsy.pages.dev/",
    "https://4f2a9c1e.bupsy.pages.dev/about", "https://site-bupsy-si-domain.bupsy.pages.dev/about"]) {
    const res = await run(url, { headers: { accept: "text/html" } });
    assert.notEqual(res.status, 301, url);
    assert.equal(res.headers.get("location"), null, url);
  }
});

test("other methods on pages are served, not redirected", async () => {
  assert.equal(redirectTo(new Request("https://bupsy.pages.dev/", { method: "POST", body: "x" })), null);
  assert.equal(redirectTo(new Request("https://www.bupsy.si/contact", { method: "OPTIONS" })), null);
});
