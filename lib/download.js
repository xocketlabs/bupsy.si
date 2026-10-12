// The download form: an email address in, the DMG's address out. Shares the list (and its checks)
// with the waitlist in lib/waitlist.js, so an address that joined the waitlist and later downloads
// is one row, not two.
import { cleanEmail, LIMITS } from "./waitlist.js";

// `Bupsy.dmg` is published under a fixed name on every release (scripts/package.sh), so this
// address always serves the newest build. Change it here if releases move to another repository
// (the RELEASE_REPO variable in .github/workflows/release.yml).
export const DOWNLOAD_URL = "https://github.com/xocketlabs/bupsy.si/releases/latest/download/Bupsy.dmg";
export const SOURCE_URL = "https://github.com/xocketlabs/bupsy.si";
export const RELEASES_URL = "https://github.com/xocketlabs/bupsy.si/releases/latest";

/**
 * Records a download for an address. `updates` is the person's own opt-in to the monthly email;
 * it can be turned on by a later download but never turned off by one (unsubscribing is a request,
 * not a missing tick). Resolves to `{ ok: true, url, already }` or `{ ok: false, status, code, error }`.
 */
export async function recordDownload(db, { email, updates, source, country }) {
  if (!db) return { ok: false, status: 503, code: "unavailable", error: "Downloads aren't open just now. Try again soon." };
  const clean = cleanEmail(email);
  if (!clean) return { ok: false, status: 400, code: "invalid_email", error: "That doesn't look like an email address." };
  const now = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  const existing = await db.prepare("SELECT id FROM waitlist WHERE email = ?1").bind(clean).first();
  await db
    .prepare(`INSERT INTO waitlist (email, source, country, updates, downloads, last_download_at)
              VALUES (?1, ?2, ?3, ?4, 1, ?5)
              ON CONFLICT (email) DO UPDATE SET
                updates = MAX(updates, excluded.updates),
                downloads = downloads + 1,
                last_download_at = excluded.last_download_at`)
    .bind(clean, String(source ?? "").slice(0, LIMITS.source), country ?? null, updates === true ? 1 : 0, now)
    .run();
  return { ok: true, url: DOWNLOAD_URL, already: !!existing };
}
