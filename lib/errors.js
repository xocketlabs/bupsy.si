// Errors every API on this site returns, as RFC 9457 problem details (application/problem+json).
//
// Agents get a stable `code` to branch on, a `detail` for people, and a `resolution` saying what to
// do next; the site's own forms keep reading `error`, which carries the same sentence. Every code
// is listed in the OpenAPI document (site/openapi.json, ErrorCode) and on /developers#errors.

const DOCS = "https://bupsy.pages.dev/developers#errors";

export const ERRORS = {
  invalid_json: { status: 400, title: "Invalid JSON", resolution: "Send a JSON object as the request body, with Content-Type: application/json." },
  invalid_body: { status: 400, title: "Invalid request body", resolution: "Send a JSON object, not an array, a string or null." },
  invalid_email: { status: 400, title: "Invalid email address", resolution: "Send the person's email address in the `email` field, e.g. name@example.com." },
  empty_message: { status: 400, title: "Empty message", resolution: "Put the message text in the `message` field." },
  message_too_long: { status: 400, title: "Message too long", resolution: "Keep `message` under 4,000 characters." },
  not_found: { status: 404, title: "Not found", resolution: "See https://bupsy.pages.dev/openapi.json for the endpoints this site has." },
  method_not_allowed: { status: 405, title: "Method not allowed", resolution: "Use the method listed in the Allow header; see https://bupsy.pages.dev/openapi.json." },
  unavailable: { status: 503, title: "Temporarily unavailable", resolution: "Try again in a few minutes." },
  server_error: { status: 500, title: "Something went wrong", resolution: "Try again. If it keeps happening, email remotevansh@gmail.com." },
};

/** The problem document for a code, with a person-readable `detail`. */
export function problemBody(code, detail, instance) {
  const known = ERRORS[code] ?? ERRORS.server_error;
  return {
    type: `${DOCS}-${code.replace(/_/g, "-")}`,
    title: known.title,
    status: known.status,
    detail,
    code,
    error: detail,
    resolution: known.resolution,
    documentation_url: DOCS,
    ...(instance ? { instance } : {}),
  };
}

/** A problem-details response. `headers` adds to the defaults (e.g. Allow on a 405). */
export function problem(code, detail, { instance, headers = {} } = {}) {
  const body = problemBody(code, detail, instance);
  return new Response(JSON.stringify(body), {
    status: body.status,
    headers: { "content-type": "application/problem+json", "cache-control": "no-store", ...headers },
  });
}

export function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
