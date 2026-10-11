import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { ERRORS, problem } from "../../lib/errors.js";
import * as waitlistApi from "../../functions/api/waitlist.js";
import * as contactApi from "../../functions/api/contact.js";
import * as catchAll from "../../functions/api/[[path]].js";
import { onRequest as middleware } from "../../functions/_middleware.js";
import { assets, fakeD1, post, SITE } from "./helpers.mjs";

const spec = JSON.parse(await readFile(SITE + "openapi.json", "utf8"));

async function expectProblem(res, status, code) {
  assert.equal(res.status, status);
  assert.equal(res.headers.get("content-type"), "application/problem+json");
  const body = await res.json();
  for (const key of ["type", "title", "status", "detail", "code", "resolution", "error"]) assert.ok(body[key] !== undefined, key);
  assert.equal(body.status, status);
  assert.equal(body.code, code);
  assert.equal(body.error, body.detail); // the site's forms read `error`
  return body;
}

test("API errors are RFC 9457 problem details with a code and a resolution", async () => {
  const env = { WAITLIST: fakeD1() };
  await expectProblem(await waitlistApi.onRequestPost({ request: post("https://x/api/waitlist", "{nope"), env }), 400, "invalid_json");
  await expectProblem(await waitlistApi.onRequestPost({ request: post("https://x/api/waitlist", "[1]"), env }), 400, "invalid_body");
  await expectProblem(await waitlistApi.onRequestPost({ request: post("https://x/api/waitlist", { email: "bad" }), env }), 400, "invalid_email");
  await expectProblem(await waitlistApi.onRequestPost({ request: post("https://x/api/waitlist", { email: "a@b.co" }), env: {} }), 503, "unavailable");
  await expectProblem(await contactApi.onRequestPost({ request: post("https://x/api/contact", { email: "a@b.co", message: "" }), env }), 400, "empty_message");
  await expectProblem(await contactApi.onRequestPost({ request: post("https://x/api/contact", { email: "a@b.co", message: "x".repeat(4001) }), env }), 400, "message_too_long");
  const method = waitlistApi.onRequest({ request: new Request("https://x/api/waitlist") });
  await expectProblem(method, 405, "method_not_allowed");
  assert.equal(method.headers.get("allow"), "POST");
});

test("a database failure is a 500 problem, not a crash", async () => {
  const broken = { prepare() { throw new Error("db down"); } };
  const original = console.error; console.error = () => {};
  try {
    await expectProblem(await waitlistApi.onRequestPost({ request: post("https://x/api/waitlist", { email: "a@b.co" }), env: { WAITLIST: broken } }), 500, "server_error");
  } finally { console.error = original; }
});

test("unknown /api/ addresses answer a JSON 404", async () => {
  const body = await expectProblem(catchAll.onRequest({ request: new Request("https://x/api/nothing-here") }), 404, "not_found");
  assert.equal(body.instance, "/api/nothing-here");
});

test("a 404 asked for as JSON comes back as JSON", async () => {
  const res = await middleware({
    request: new Request("https://bupsy.pages.dev/nope", { headers: { accept: "application/json" } }),
    env: { ASSETS: assets },
    next: async () => new Response("<html>missing</html>", { status: 404, headers: { "content-type": "text/html" } }),
  });
  await expectProblem(res, 404, "not_found");
});

test("every error code the API returns is in the OpenAPI ErrorCode enum, and back", () => {
  assert.deepEqual([...spec.components.schemas.ErrorCode.enum].sort(), Object.keys(ERRORS).sort());
  assert.equal(problem("invalid_email", "x").status, 400);
});

test("the OpenAPI document is self-describing enough for function calling", () => {
  assert.equal(spec.openapi, "3.1.0");
  assert.deepEqual(spec.security, []);
  const ids = [];
  const resolve = (ref) => ref.replace("#/components/", "").split("/").reduce((node, key) => node[key], spec.components);
  for (const [path, item] of Object.entries(spec.paths)) {
    for (const [method, op] of Object.entries(item)) {
      assert.ok(op.operationId, `${method} ${path} operationId`);
      assert.ok(op.description && op.summary, `${op.operationId} description`);
      ids.push(op.operationId);
      const schema = op.requestBody.content["application/json"].schema;
      assert.ok(resolve(schema.$ref).type === "object", `${op.operationId} request schema`);
      const ok = op.responses["200"].content["application/json"].schema;
      assert.ok(resolve(ok.$ref), `${op.operationId} 200 schema`);
    }
  }
  assert.deepEqual(ids, ["joinWaitlist", "sendContactMessage", "callMcp"]);
  assert.equal(new Set(ids).size, ids.length);
});

test("the spec matches what the endpoints accept", () => {
  const waitlist = spec.components.schemas.WaitlistRequest;
  assert.deepEqual(waitlist.required, ["email"]);
  assert.equal(waitlist.properties.email.maxLength, 254);
  assert.equal(spec.components.schemas.ContactRequest.properties.message.maxLength, 4000);
});
