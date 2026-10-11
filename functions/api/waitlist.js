// POST /api/waitlist — adds an email to the waitlist (lib/waitlist.js), from the site's forms.
import { joinWaitlist } from "../../lib/waitlist.js";
import { json, problem } from "../../lib/errors.js";

export async function onRequestPost({ request, env }) {
  let body;
  try { body = await request.json(); } catch { return problem("invalid_json", "The request body isn't valid JSON.", { instance: new URL(request.url).pathname }); }
  // `null`, a number or an array parse as JSON too, and reading a field off null would throw
  // outside any try — an unhandled 500 for what is just a bad request.
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return problem("invalid_body", "The request body must be a JSON object.", { instance: new URL(request.url).pathname });
  }
  // A field people never see. Anything in it is a bot; pretend it worked and store nothing.
  if (body.company) return json({ ok: true });

  try {
    const result = await joinWaitlist(env.WAITLIST, {
      email: body.email, source: body.source, country: request.cf?.country,
    });
    return result.ok ? json({ ok: true, already: result.already }) : problem(result.code, result.error, { instance: new URL(request.url).pathname });
  } catch (err) {
    console.error(err);
    return problem("server_error", "Couldn't save that just now. Please try again.", { instance: new URL(request.url).pathname });
  }
}

export function onRequest({ request }) {
  return problem("method_not_allowed", "Use POST.", { instance: new URL(request.url).pathname, headers: { allow: "POST" } });
}
