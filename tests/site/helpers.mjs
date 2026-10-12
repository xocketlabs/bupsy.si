// Stand-ins for what Cloudflare Pages gives a function: the D1 binding and the static assets.
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

export const SITE = fileURLToPath(new URL("../../site/", import.meta.url));

/**
 * A D1 database holding the waitlist and messages tables in memory. It understands the
 * statements lib/waitlist.js and lib/download.js send, nothing more; download.test.mjs also
 * runs lib/download.js against real SQLite and the migrations, to keep this stand-in honest.
 */
export function fakeD1() {
  const waitlist = new Map();
  const messages = [];
  let nextId = 1;
  return {
    waitlist, messages,
    prepare(sql) {
      return {
        bind(...args) {
          return {
            async first() {
              if (sql.startsWith("SELECT id FROM waitlist WHERE email = ?1")) {
                const row = waitlist.get(args[0]);
                return row ? { id: row.id } : null;
              }
              throw new Error(`unexpected SQL: ${sql}`);
            },
            async run() {
              // The download form's upsert: a new row, or one more download on the old one.
              if (sql.startsWith("INSERT INTO waitlist") && /ON CONFLICT \(email\) DO UPDATE/.test(sql)) {
                const [email, source, country, updates, now] = args;
                const row = waitlist.get(email);
                if (row) {
                  row.updates = Math.max(row.updates, updates);
                  row.downloads += 1;
                  row.last_download_at = now;
                } else {
                  waitlist.set(email, { id: nextId++, email, source, country, updates, downloads: 1, last_download_at: now });
                }
                return { meta: { changes: 1 } };
              }
              if (sql.startsWith("INSERT INTO waitlist")) {
                const [email, source, country] = args;
                if (waitlist.has(email)) return { meta: { changes: 0 } };
                waitlist.set(email, { id: nextId++, email, source, country, updates: 0, downloads: 0, last_download_at: null });
                return { meta: { changes: 1 } };
              }
              if (sql.startsWith("INSERT INTO messages")) {
                const [name, email, message, country] = args;
                messages.push({ name, email, message, country });
                return { meta: { changes: 1 } };
              }
              throw new Error(`unexpected SQL: ${sql}`);
            },
          };
        },
      };
    },
  };
}

/** The ASSETS binding: serves files from site/, 404 for anything missing. */
export const assets = {
  async fetch(url) {
    const path = new URL(url).pathname;
    try {
      const body = await readFile(SITE + path.replace(/^\//, ""), "utf8");
      return new Response(body, { status: 200 });
    } catch {
      return new Response("not found", { status: 404 });
    }
  },
};

export function post(url, body, headers = {}) {
  return new Request(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}
