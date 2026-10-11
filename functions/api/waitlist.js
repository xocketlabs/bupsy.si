// POST /api/waitlist — adds an email to the waitlist (lib/waitlist.js), from the site's forms.
import { joinWaitlist } from "../../lib/waitlist.js";

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

export async function onRequestPost({ request, env }) {
  let body;
  try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }
  // `null`, a number or an array parse as JSON too, and reading a field off null would throw
  // outside any try — an unhandled 500 for what is just a bad request.
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return json({ error: "Bad request." }, 400);
  }
  // A field people never see. Anything in it is a bot; pretend it worked and store nothing.
  if (body.company) return json({ ok: true });

  try {
    const result = await joinWaitlist(env.WAITLIST, {
      email: body.email, source: body.source, country: request.cf?.country,
    });
    return result.ok ? json({ ok: true, already: result.already }) : json({ error: result.error }, result.status);
  } catch (err) {
    console.error(err);
    return json({ error: "Couldn't save that just now — please try again." }, 500);
  }
}

export function onRequest() {
  return json({ error: "Use POST." }, 405);
}
