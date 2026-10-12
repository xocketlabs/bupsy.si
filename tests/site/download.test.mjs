import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { recordDownload, DOWNLOAD_URL } from "../../lib/download.js";
import { joinWaitlist } from "../../lib/waitlist.js";
import * as downloadApi from "../../functions/api/download.js";
import { fakeD1, post } from "./helpers.mjs";

const URL_ = "https://bupsy.si/api/download";
const download = (body, env) => downloadApi.onRequestPost({ request: post(URL_, body), env });

async function expectProblem(res, status, code) {
  assert.equal(res.status, status);
  assert.equal(res.headers.get("content-type"), "application/problem+json");
  const body = await res.json();
  assert.equal(body.code, code);
  assert.equal(body.error, body.detail);
  return body;
}

test("a new address gets the DMG's address, already false, and its tick stored as is", async () => {
  const db = fakeD1();
  const env = { WAITLIST: db };
  const res = await download({ email: "New@Example.com", source: "hero" }, env);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, url: DOWNLOAD_URL, already: false });
  const row = db.waitlist.get("new@example.com");
  assert.equal(row.updates, 0);
  assert.equal(row.downloads, 1);
  assert.equal(row.source, "hero");
  assert.match(row.last_download_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);

  await download({ email: "ticked@example.com", updates: true }, env);
  assert.equal(db.waitlist.get("ticked@example.com").updates, 1);
  // Only a real true is a tick: a string or a number is not the person's opt-in.
  await download({ email: "string@example.com", updates: "true" }, env);
  assert.equal(db.waitlist.get("string@example.com").updates, 0);
});

test("a repeat download counts again and says already", async () => {
  const db = fakeD1();
  await download({ email: "a@b.co", source: "hero" }, { WAITLIST: db });
  const again = await (await download({ email: "a@b.co", source: "footer" }, { WAITLIST: db })).json();
  assert.deepEqual(again, { ok: true, url: DOWNLOAD_URL, already: true });
  const row = db.waitlist.get("a@b.co");
  assert.equal(row.downloads, 2);
  assert.equal(row.source, "hero");
});

test("the monthly email can be turned on later, and an unticked download never turns it off", async () => {
  const db = fakeD1();
  await recordDownload(db, { email: "a@b.co", updates: false });
  assert.equal(db.waitlist.get("a@b.co").updates, 0);
  await recordDownload(db, { email: "a@b.co", updates: true });
  assert.equal(db.waitlist.get("a@b.co").updates, 1);
  await recordDownload(db, { email: "a@b.co" });
  await recordDownload(db, { email: "a@b.co", updates: false });
  assert.equal(db.waitlist.get("a@b.co").updates, 1);
  assert.equal(db.waitlist.get("a@b.co").downloads, 4);
});

test("an address already on the list from the waitlist downloads as the same row", async () => {
  const db = fakeD1();
  await joinWaitlist(db, { email: "a@b.co", source: "hero" });
  const result = await recordDownload(db, { email: "a@b.co", source: "download" });
  assert.equal(result.already, true);
  assert.equal(db.waitlist.size, 1);
  assert.equal(db.waitlist.get("a@b.co").downloads, 1);
});

test("the honeypot stores nothing but still hands back the address", async () => {
  const db = fakeD1();
  const res = await download({ email: "bot@example.com", company: "Acme" }, { WAITLIST: db });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, url: DOWNLOAD_URL, already: false });
  assert.equal(db.waitlist.size, 0);
});

test("bad input, no database and the wrong method are problem details", async () => {
  const env = { WAITLIST: fakeD1() };
  await expectProblem(await download({ email: "nope" }, env), 400, "invalid_email");
  await expectProblem(await download({}, env), 400, "invalid_email");
  await expectProblem(await download("{nope", env), 400, "invalid_json");
  await expectProblem(await download("null", env), 400, "invalid_body");
  await expectProblem(await download("[1]", env), 400, "invalid_body");
  assert.equal(env.WAITLIST.waitlist.size, 0);
  await expectProblem(await download({ email: "a@b.co" }, {}), 503, "unavailable");
  const method = downloadApi.onRequest({ request: new Request(URL_) });
  await expectProblem(method, 405, "method_not_allowed");
  assert.equal(method.headers.get("allow"), "POST");
});

test("a database failure is a 500 problem, not a crash", async () => {
  const broken = { prepare() { throw new Error("db down"); } };
  const original = console.error; console.error = () => {};
  try {
    await expectProblem(await download({ email: "a@b.co" }, { WAITLIST: broken }), 500, "server_error");
  } finally { console.error = original; }
});

// The same SQL against real SQLite with every migration applied, so the fake above can't drift
// from what D1 actually runs. Skipped where node:sqlite isn't available.
let sqlite = null;
try { sqlite = await import("node:sqlite"); } catch {}

/** A D1-shaped wrapper over node:sqlite: prepare(sql).bind(...).first() / .run(). */
function realD1() {
  const db = new sqlite.DatabaseSync(":memory:");
  return {
    db,
    prepare(sql) {
      return {
        bind(...args) {
          // D1 numbers its parameters (?1, ?2); some node:sqlite versions reject that with
          // positional values, so number them by order of appearance instead.
          const ordered = [];
          const plain = sql.replace(/\?(\d+)/g, (_, n) => { ordered.push(args[Number(n) - 1]); return "?"; });
          args = ordered.length ? ordered : args;
          const statement = db.prepare(plain);
          return {
            async first() { return statement.get(...args) ?? null; },
            async run() { return { meta: { changes: Number(statement.run(...args).changes) } }; },
          };
        },
      };
    },
  };
}

test("recordDownload's SQL works on SQLite with the migrations applied", { skip: !sqlite && "node:sqlite unavailable" }, async () => {
  const d1 = realD1();
  const dir = fileURLToPath(new URL("../../migrations/", import.meta.url));
  for (const file of (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort()) {
    d1.db.exec(await readFile(dir + file, "utf8"));
  }
  assert.equal((await joinWaitlist(d1, { email: "old@b.co", source: "hero" })).already, false);
  assert.deepEqual(await recordDownload(d1, { email: "a@b.co", updates: false, source: "hero", country: "IN" }), { ok: true, url: DOWNLOAD_URL, already: false });
  assert.deepEqual(await recordDownload(d1, { email: "a@b.co", updates: true, source: "footer" }), { ok: true, url: DOWNLOAD_URL, already: true });
  await recordDownload(d1, { email: "a@b.co", updates: false });
  assert.equal((await recordDownload(d1, { email: "old@b.co" })).already, true);

  const row = d1.db.prepare("SELECT * FROM waitlist WHERE email = ?").get("a@b.co");
  assert.equal(row.updates, 1);
  assert.equal(row.downloads, 3);
  assert.equal(row.source, "hero");
  assert.equal(row.country, "IN");
  assert.match(row.last_download_at, /Z$/);
  const old = d1.db.prepare("SELECT updates, downloads FROM waitlist WHERE email = ?").get("old@b.co");
  assert.deepEqual({ ...old }, { updates: 0, downloads: 1 });
});
