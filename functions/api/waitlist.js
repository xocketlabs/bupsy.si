// POST /api/waitlist — adds an email to the waitlist in Neon Postgres.
//
// Runs as a Cloudflare Pages Function beside the landing page. The database connection string is
// a Pages secret (DATABASE_URL); it never reaches the browser. Neon's SQL-over-HTTP endpoint means
// no driver and no npm dependency — one fetch per signup.
//
// The table is created on first use, so there is no separate migration step to forget.

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

async function sql(connection, query, params = []) {
  const host = new URL(connection.replace(/^postgres(ql)?:/, "https:")).hostname;
  const res = await fetch(`https://${host}/sql`, {
    method: "POST",
    headers: { "content-type": "application/json", "Neon-Connection-String": connection },
    body: JSON.stringify({ query, params }),
  });
  if (!res.ok) throw new Error(`neon ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return res.json();
}

export async function onRequestPost({ request, env }) {
  if (!env.DATABASE_URL) return json({ error: "The waitlist isn't open yet — try again soon." }, 503);

  let body;
  try { body = await request.json(); } catch { return json({ error: "Bad request." }, 400); }

  // A field people never see. Anything in it is a bot; pretend it worked and store nothing.
  if (body.company) return json({ ok: true });

  const email = String(body.email || "").trim().toLowerCase();
  if (email.length > 254 || !EMAIL.test(email)) {
    return json({ error: "That doesn't look like an email address." }, 400);
  }
  const source = String(body.source || "").slice(0, 32);
  const country = request.cf?.country || null;

  try {
    await sql(env.DATABASE_URL, `
      CREATE TABLE IF NOT EXISTS waitlist (
        id bigserial PRIMARY KEY,
        email text NOT NULL UNIQUE,
        source text,
        country text,
        created_at timestamptz NOT NULL DEFAULT now()
      )`);
    const result = await sql(env.DATABASE_URL,
      `INSERT INTO waitlist (email, source, country) VALUES ($1, $2, $3)
       ON CONFLICT (email) DO NOTHING RETURNING id`,
      [email, source, country]);
    return json({ ok: true, already: (result.rows || []).length === 0 });
  } catch (err) {
    console.error(err);
    return json({ error: "Couldn't save that just now — please try again." }, 500);
  }
}

export function onRequest() {
  return json({ error: "Use POST." }, 405);
}
