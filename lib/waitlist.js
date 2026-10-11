// The waitlist and the contact form, shared by the site's forms (functions/api/) and the public
// MCP server (functions/mcp.js), so a signup is checked and stored the same way wherever it
// comes from. Both write to the D1 database bound as WAITLIST (wrangler.toml).

// Deliberately loose about what an address may be, strict about what it may not contain: no
// whitespace, and none of < > " ' — characters a real address almost never has and markup or a
// quoted header always does. These rows get read in admin tools and pasted into mail clients
// later, so anything that could break out of where it is shown is refused at the door.
const EMAIL = /^[^\s@<>"']+@[^\s@<>"']+\.[^\s@<>"']+$/;

export const LIMITS = { email: 254, source: 32, name: 100, message: 4000 };

/** A cleaned address, or null when it isn't one. */
export function cleanEmail(raw) {
  const email = String(raw ?? "").trim().toLowerCase();
  return email.length <= LIMITS.email && EMAIL.test(email) ? email : null;
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
