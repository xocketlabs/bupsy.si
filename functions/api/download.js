// POST /api/download: records the address (lib/download.js) and answers with the DMG's address,
// which the page then opens. No account and no confirmation step: the address is the price of the
// download, and the monthly email is a separate tick box.
import { recordDownload, DOWNLOAD_URL } from "../../lib/download.js";
import { json, problem } from "../../lib/errors.js";

export async function onRequestPost({ request, env }) {
  const instance = new URL(request.url).pathname;
  let body;
  try { body = await request.json(); } catch { return problem("invalid_json", "The request body isn't valid JSON.", { instance }); }
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return problem("invalid_body", "The request body must be a JSON object.", { instance });
  }
  // The field people never see. A bot filled it: hand back the link anyway and store nothing,
  // so it learns nothing from the answer.
  if (body.company) return json({ ok: true, url: DOWNLOAD_URL, already: false });
  try {
    const result = await recordDownload(env.WAITLIST, {
      email: body.email, updates: body.updates, source: body.source, country: request.cf?.country,
    });
    return result.ok ? json({ ok: true, url: result.url, already: result.already }) : problem(result.code, result.error, { instance });
  } catch (err) {
    console.error(err);
    return problem("server_error", "Couldn't start the download just now. Please try again.", { instance });
  }
}

export function onRequest({ request }) {
  return problem("method_not_allowed", "Use POST.", { instance: new URL(request.url).pathname, headers: { allow: "POST" } });
}
