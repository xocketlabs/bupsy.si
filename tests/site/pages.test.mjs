import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, access } from "node:fs/promises";
import { onRequest, PAGES, wantsMarkdown } from "../../functions/_middleware.js";
import { assets, SITE } from "./helpers.mjs";

const read = (path) => readFile(SITE + path, "utf8");
const html = (body = "<html></html>", status = 200) =>
  new Response(body, { status, headers: { "content-type": "text/html; charset=utf-8" } });
const run = (path, accept, next = async () => html()) =>
  onRequest({ request: new Request("https://bupsy.pages.dev" + path, { headers: { accept } }), env: { ASSETS: assets }, next });

test("Markdown is served when asked for, with Vary: Accept", async () => {
  for (const path of ["/", "/about", "/privacy", "/developers", "/contact"]) {
    const res = await run(path, "text/markdown");
    assert.equal(res.status, 200, path);
    assert.match(res.headers.get("content-type"), /^text\/markdown/, path);
    assert.equal(res.headers.get("vary"), "Accept", path);
    assert.match(await res.text(), /^# /, path);
  }
});

test("browsers get HTML, also with Vary: Accept", async () => {
  const res = await run("/", "text/html,application/xhtml+xml,*/*;q=0.8");
  assert.match(res.headers.get("content-type"), /text\/html/);
  assert.equal(res.headers.get("vary"), "Accept");
  assert.equal(wantsMarkdown(new Request("https://x/", { headers: { accept: "text/html, text/markdown" } })), false);
});

test("unknown paths are 404, in Markdown when asked", async () => {
  const res = await run("/nope", "text/markdown", async () => html("missing", 404));
  assert.equal(res.status, 404);
  assert.match(res.headers.get("content-type"), /^text\/markdown/);
  assert.match(await res.text(), /llms\.txt/);
});

test("every page has its Markdown twin and HTML page, and is in the sitemap", async () => {
  const sitemap = await read("sitemap.xml");
  for (const [path, md] of Object.entries(PAGES)) {
    await access(SITE + md.slice(1));
    if (path !== "/index.html") assert.match(sitemap, new RegExp(`<loc>https://bupsy.pages.dev${path === "/" ? "/" : path}</loc>`), path);
  }
  for (const name of ["about", "privacy", "developers", "contact", "404"]) await access(`${SITE}${name}.html`);
});

test("trust pages carry at least 500 characters of text", async () => {
  for (const name of ["about", "privacy", "contact", "developers"]) {
    const text = (await read(`${name}.md`)).replace(/<!--.*?-->/g, "");
    assert.ok(text.length >= 500, `${name}: ${text.length}`);
  }
});

test("llms.txt and agents.md say when to use Bupsy and how to call it", async () => {
  for (const file of ["llms.txt", "agents.md"]) {
    const text = await read(file);
    assert.match(text, /## When to use Bupsy/, file);
    assert.match(text, /https:\/\/bupsy\.pages\.dev\/mcp/, file);
  }
});

test("the MCP server card has the fields discovery checks for", async () => {
  for (const file of [".well-known/mcp/server-card.json", ".well-known/mcp.json"]) {
    const card = JSON.parse(await read(file));
    assert.equal(card.serverInfo.name, "bupsy");
    assert.ok(card.serverInfo.version);
    assert.equal(card.transport.endpoint, "/mcp");
    assert.deepEqual(card.capabilities, { tools: true, resources: false, prompts: false });
  }
  const catalog = JSON.parse(await read(".well-known/api-catalog"));
  assert.ok(catalog.linkset.some((entry) => entry.anchor === "https://bupsy.pages.dev/mcp"));
});

test("the homepage's JSON-LD parses and names the product and its maker", async () => {
  const page = await read("index.html");
  const block = page.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1];
  const items = JSON.parse(block);
  const types = items.map((item) => item["@type"]);
  assert.deepEqual(types, ["SoftwareApplication", "Organization", "WebSite"]);
  assert.equal(items[1].contactPoint.url, "https://bupsy.pages.dev/contact");
  assert.match(items[1].contactPoint.email, /@/);
  assert.equal(items[1].address["@type"], "PostalAddress");
  assert.match(page, /<link rel="canonical" href="https:\/\/bupsy.pages.dev\/">/);
});
