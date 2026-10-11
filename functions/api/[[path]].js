// Any /api/ address that isn't an endpoint: a JSON 404 rather than the site's HTML 404 page, so an
// agent probing the API learns there is nothing there, and where the list of endpoints is.
import { problem } from "../../lib/errors.js";

export function onRequest({ request }) {
  const path = new URL(request.url).pathname;
  return problem("not_found", `There is no API endpoint at ${path}.`, { instance: path });
}
