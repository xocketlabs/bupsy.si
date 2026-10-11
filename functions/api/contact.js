// POST /api/contact — a message from the contact page, kept in D1 for us to answer by email.
import { sendMessage } from "../../lib/waitlist.js";

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

export async function onRequestPost({ request, env }) {
  let body;
  try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return json({ error: "Bad request." }, 400);
  }
  // The same hidden field as the waitlist: filled in only by bots.
  if (body.company) return json({ ok: true });

  try {
    const result = await sendMessage(env.WAITLIST, {
      name: body.name, email: body.email, message: body.message, country: request.cf?.country,
    });
    return result.ok ? json({ ok: true }) : json({ error: result.error }, result.status);
  } catch (err) {
    console.error(err);
    return json({ error: "Couldn't send that just now — please try again." }, 500);
  }
}

export function onRequest() {
  return json({ error: "Use POST." }, 405);
}
