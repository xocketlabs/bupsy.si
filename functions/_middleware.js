import { problem } from "../lib/errors.js";

// Markdown for agents that ask for it, HTML for everyone else.
//
// An agent sending `Accept: text/markdown` gets the page's Markdown twin (index.md, about.md…)
// instead of the HTML, which is most of the tokens and none of the meaning. Browsers never send
// that header, so people always get the page. Unknown paths answer 404 either way, with a Markdown
// body pointing at llms.txt and the sitemap when Markdown was asked for.

export const PAGES = {
  "/": "/index.md", "/index.html": "/index.md", "/about": "/about.md", "/privacy": "/privacy.md",
  "/developers": "/developers.md", "/contact": "/contact.md",
};

// The site's one address. The old Pages address and www answer with a 301 to the same path here,
// so links and search results carry over. Only for reads of pages: the API and the MCP server keep
// answering on the old addresses (a 301 on a POST breaks clients), and deploy previews
// (<hash>.bupsy.pages.dev) are left alone so they stay usable.
export const ORIGIN = "https://bupsy.si";
const OLD_HOSTS = new Set(["bupsy.pages.dev", "www.bupsy.si"]);

export function redirectTo(request) {
  const url = new URL(request.url);
  if (!OLD_HOSTS.has(url.hostname)) return null;
  if (request.method !== "GET" && request.method !== "HEAD") return null;
  const path = url.pathname.replace(/\/+$/, "") || "/";
  if (path.startsWith("/api/") || path === "/api" || path === "/mcp") return null;
  return ORIGIN + url.pathname + url.search;
}

export function wantsJson(request) {
  const accept = request.headers.get("accept") || "";
  return /application\/(problem\+)?json/i.test(accept.split(",")[0]);
}

export function wantsMarkdown(request) {
  const accept = request.headers.get("accept") || "";
  return /text\/markdown/i.test(accept) && !/text\/html/i.test(accept.split(",")[0]);
}

async function markdown(env, request, path, status) {
  const res = await env.ASSETS.fetch(new URL(path, request.url));
  if (!res.ok) return null;
  return new Response(await res.text(), {
    status,
    headers: { "content-type": "text/markdown; charset=utf-8", "vary": "Accept", "cache-control": "public, max-age=300" },
  });
}

export async function onRequest(context) {
  const { request, env, next } = context;
  const moved = redirectTo(request);
  if (moved) return new Response(null, { status: 301, headers: { location: moved, "cache-control": "public, max-age=86400" } });

  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const markdownWanted = request.method === "GET" && wantsMarkdown(request) && !path.startsWith("/api/") && path !== "/mcp";

  if (markdownWanted && PAGES[path]) {
    const page = await markdown(env, request, PAGES[path], 200);
    if (page) return page;
  }

  const response = await next();
  if (markdownWanted && response.status === 404) {
    return (await markdown(env, request, "/404.md", 404)) || response;
  }
  // An agent asking for JSON gets its 404 as JSON too, never the HTML page.
  if (response.status === 404 && wantsJson(request) && !markdownWanted) {
    return problem("not_found", `There is nothing at ${url.pathname}.`, { instance: url.pathname });
  }
  // The same address answers differently by Accept, so caches must keep them apart.
  if (PAGES[path] && (response.headers.get("content-type") || "").includes("text/html")) {
    const headers = new Headers(response.headers);
    headers.set("vary", "Accept");
    return new Response(response.body, { status: response.status, headers });
  }
  return response;
}
