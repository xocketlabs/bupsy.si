// Stand-ins for what Cloudflare Pages gives a function: the D1 binding and the static assets.
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

export const SITE = fileURLToPath(new URL("../../site/", import.meta.url));

/** A D1 database holding the waitlist and messages tables in memory. */
export function fakeD1() {
  const waitlist = new Map();
  const messages = [];
  return {
    waitlist, messages,
    prepare(sql) {
      return {
        bind(...args) {
          return {
            async run() {
              if (sql.startsWith("INSERT INTO waitlist")) {
                const [email, source, country] = args;
                if (waitlist.has(email)) return { meta: { changes: 0 } };
                waitlist.set(email, { email, source, country });
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
