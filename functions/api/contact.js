// POST /api/contact — a message from the contact page, kept in D1 for us to answer by email.
import { sendMessage } from "../../lib/waitlist.js";
import { json, problem } from "../../lib/errors.js";

export async function onRequestPost({ request, env }) {
  let body;
  try { body = await request.json(); } catch { return problem("invalid_json", "The request body isn't valid JSON.", { instance: new URL(request.url).pathname }); }
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return problem("invalid_body", "The request body must be a JSON object.", { instance: new URL(request.url).pathname });
  }
  // The same hidden field as the waitlist: filled in only by bots.
  if (body.company) return json({ ok: true });

  try {
    const result = await sendMessage(env.WAITLIST, {
      name: body.name, email: body.email, message: body.message, country: request.cf?.country,
    });
    return result.ok ? json({ ok: true }) : problem(result.code, result.error, { instance: new URL(request.url).pathname });
  } catch (err) {
    console.error(err);
    return problem("server_error", "Couldn't send that just now. Please try again.", { instance: new URL(request.url).pathname });
  }
}

export function onRequest({ request }) {
  return problem("method_not_allowed", "Use POST.", { instance: new URL(request.url).pathname, headers: { allow: "POST" } });
}
