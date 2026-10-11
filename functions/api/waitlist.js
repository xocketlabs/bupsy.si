// POST /api/waitlist — adds an email to the waitlist in Cloudflare D1.
//
// Runs as a Cloudflare Pages Function beside the landing page, with the D1 database bound as
// WAITLIST (see wrangler.toml). The table comes from migrations/, applied by deploy-site.sh, so a
// signup is one insert and nothing else.

// Deliberately loose about what an address may be, strict about what it may not contain: no
// whitespace, and none of < > " ' — characters a real address almost never has and markup or a
// quoted header always does. These rows get read in admin tools and pasted into mail clients
// later, so anything that could break out of where it is shown is refused at the door.
const EMAIL = /^[^\s@<>"']+@[^\s@<>"']+\.[^\s@<>"']+$/;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

export async function onRequestPost({ request, env }) {
  if (!env.WAITLIST) return json({ error: "The waitlist isn't open yet — try again soon." }, 503);

  let body;
  try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }
  // `null`, a number or an array parse as JSON too, and reading a field off null would throw
  // outside any try — an unhandled 500 for what is just a bad request.
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return json({ error: "Bad request." }, 400);
  }

  // A field people never see. Anything in it is a bot; pretend it worked and store nothing.
  if (body.company) return json({ ok: true });

  const email = String(body.email || "").trim().toLowerCase();
  if (email.length > 254 || !EMAIL.test(email)) {
    return json({ error: "That doesn't look like an email address." }, 400);
  }
  const source = String(body.source || "").slice(0, 32);
  const country = request.cf?.country || null;

  try {
    const result = await env.WAITLIST
      .prepare("INSERT INTO waitlist (email, source, country) VALUES (?1, ?2, ?3) ON CONFLICT (email) DO NOTHING")
      .bind(email, source, country)
      .run();
    return json({ ok: true, already: result.meta.changes === 0 });
  } catch (err) {
    console.error(err);
    return json({ error: "Couldn't save that just now — please try again." }, 500);
  }
}

export function onRequest() {
  return json({ error: "Use POST." }, 405);
}
