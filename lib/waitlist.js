// The waitlist and the contact form, shared by the site's forms (functions/api/) and the public
// MCP server (functions/mcp.js), so a signup is checked and stored the same way wherever it
// comes from. Both write to the D1 database bound as WAITLIST (wrangler.toml).

// Loose about the part before the @, strict about the domain. The name part refuses whitespace and
// the characters that could break out of wherever a row is later shown or pasted (< > " ' and the
// header punctuation ( ) , ; : [ ] \), and may not start, end or double up a dot. The domain must be
// real-looking: letters, digits and hyphens in dot-separated labels, ending in a letters-only TLD of
// two or more. That turns away typed junk like "name@gmai;.com" or "a@b..com", which can never
// receive the email the person asked for. Internationalised domains arrive as punycode (xn--…).
const LOCAL = /^(?!\.)(?!.*\.\.)[^\s@<>"'(),;:[\]\\]+(?<!\.)$/;
const DOMAIN = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

export const LIMITS = { email: 254, source: 32, name: 100, message: 4000 };

/** A cleaned address, or null when it isn't one. */
export function cleanEmail(raw) {
  const email = String(raw ?? "").trim().toLowerCase();
  if (email.length > LIMITS.email) return null;
  const at = email.lastIndexOf("@");
  if (at < 1 || email.indexOf("@") !== at) return null;
  const local = email.slice(0, at), domain = email.slice(at + 1);
  return local.length <= 64 && LOCAL.test(local) && DOMAIN.test(domain) ? email : null;
}

/**
 * Adds an address. Resolves to `{ ok: true, already }`, or `{ ok: false, status, code, error }`:
 * a code from lib/errors.js and a sentence for a person to read. A duplicate is not an error: it is reported as `already`.
 */
export async function joinWaitlist(db, { email, source, country }) {
  if (!db) return { ok: false, status: 503, code: "unavailable", error: "The waitlist isn't open yet. Try again soon." };
  const clean = cleanEmail(email);
  if (!clean) return { ok: false, status: 400, code: "invalid_email", error: "That doesn't look like an email address." };
  const result = await db
    .prepare("INSERT INTO waitlist (email, source, country) VALUES (?1, ?2, ?3) ON CONFLICT (email) DO NOTHING")
    .bind(clean, String(source ?? "").slice(0, LIMITS.source), country ?? null)
    .run();
  return { ok: true, already: result.meta.changes === 0 };
}

/** Keeps a message from the contact page. Same shape of result as `joinWaitlist`. */
export async function sendMessage(db, { name, email, message, country }) {
  if (!db) return { ok: false, status: 503, code: "unavailable", error: "Messages aren't open yet. Try again soon." };
  const clean = cleanEmail(email);
  if (!clean) return { ok: false, status: 400, code: "invalid_email", error: "That doesn't look like an email address." };
  const text = String(message ?? "").trim();
  if (text.length < 2) return { ok: false, status: 400, code: "empty_message", error: "Write a message first." };
  if (text.length > LIMITS.message) return { ok: false, status: 400, code: "message_too_long", error: "That's a long one. Keep it under 4,000 characters." };
  await db
    .prepare("INSERT INTO messages (name, email, message, country) VALUES (?1, ?2, ?3, ?4)")
    .bind(String(name ?? "").trim().slice(0, LIMITS.name) || null, clean, text, country ?? null)
    .run();
  return { ok: true };
}
