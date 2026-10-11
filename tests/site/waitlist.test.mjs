import { test } from "node:test";
import assert from "node:assert/strict";
import { cleanEmail, joinWaitlist, sendMessage } from "../../lib/waitlist.js";
import * as waitlistApi from "../../functions/api/waitlist.js";
import * as contactApi from "../../functions/api/contact.js";
import { fakeD1, post } from "./helpers.mjs";

test("cleanEmail lowercases, trims and refuses what isn't an address", () => {
  assert.equal(cleanEmail("  You@Example.COM "), "you@example.com");
  for (const bad of ["", "nope", "a@b", "a b@c.d", "<x>@y.z", "a\"@b.c", "x".repeat(250) + "@a.bc"]) {
    assert.equal(cleanEmail(bad), null, bad);
  }
});

test("joinWaitlist adds once, then reports a repeat as already", async () => {
  const db = fakeD1();
  assert.deepEqual(await joinWaitlist(db, { email: "A@B.co", source: "hero" }), { ok: true, already: false });
  assert.deepEqual(await joinWaitlist(db, { email: "a@b.co", source: "footer" }), { ok: true, already: true });
  assert.equal(db.waitlist.get("a@b.co").source, "hero");
});

test("joinWaitlist explains a bad address and a missing database", async () => {
  assert.equal((await joinWaitlist(fakeD1(), { email: "x" })).status, 400);
  assert.equal((await joinWaitlist(undefined, { email: "a@b.co" })).status, 503);
});

test("sendMessage needs an address and a message, and keeps the name optional", async () => {
  const db = fakeD1();
  assert.equal((await sendMessage(db, { email: "a@b.co", message: "" })).status, 400);
  assert.equal((await sendMessage(db, { email: "bad", message: "hi there" })).status, 400);
  assert.equal((await sendMessage(db, { email: "a@b.co", message: "x".repeat(4001) })).status, 400);
  assert.deepEqual(await sendMessage(db, { email: "a@b.co", message: "  Hello  " }), { ok: true });
  assert.deepEqual(db.messages[0], { name: null, email: "a@b.co", message: "Hello", country: null });
});

for (const [name, api, body] of [
  ["waitlist", waitlistApi, { email: "a@b.co" }],
  ["contact", contactApi, { email: "a@b.co", message: "Hello there" }],
]) {
  test(`/api/${name}: saves, ignores the honeypot, refuses bad JSON and GET`, async () => {
    const db = fakeD1();
    const env = { WAITLIST: db };
    const ok = await api.onRequestPost({ request: post(`https://x/api/${name}`, body), env });
    assert.equal(ok.status, 200);
    assert.equal(db.waitlist.size + db.messages.length, 1);

    const trap = await api.onRequestPost({ request: post(`https://x/api/${name}`, { ...body, company: "bot" }), env });
    assert.equal(trap.status, 200);
    assert.equal(db.waitlist.size + db.messages.length, 1);

    assert.equal((await api.onRequestPost({ request: post(`https://x/api/${name}`, "{nope"), env })).status, 400);
    assert.equal((await api.onRequestPost({ request: post(`https://x/api/${name}`, "null"), env })).status, 400);
    assert.equal(api.onRequest().status, 405);
  });
}
