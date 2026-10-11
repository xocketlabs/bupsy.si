// Markdown for agents that ask for it, HTML for everyone else.
//
// An agent sending `Accept: text/markdown` gets the page's Markdown twin (index.md, about.md…)
// instead of the HTML, which is most of the tokens and none of the meaning. Browsers never send
// that header, so people always get the page. Unknown paths answer 404 either way, with a Markdown
// body pointing at llms.txt and the sitemap when Markdown was asked for.

const PAGES = { "/": "/index.md", "/index.html": "/index.md", "/about": "/about.md", "/privacy": "/privacy.md" };

function wantsMarkdown(request) {
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
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const markdownWanted = request.method === "GET" && wantsMarkdown(request) && !path.startsWith("/api/");

  if (markdownWanted && PAGES[path]) {
    const page = await markdown(env, request, PAGES[path], 200);
    if (page) return page;
  }

  const response = await next();
  if (markdownWanted && response.status === 404) {
    return (await markdown(env, request, "/404.md", 404)) || response;
  }
  // The same address answers differently by Accept, so caches must keep them apart.
  if (PAGES[path] && (response.headers.get("content-type") || "").includes("text/html")) {
    const headers = new Headers(response.headers);
    headers.set("vary", "Accept");
    return new Response(response.body, { status: response.status, headers });
  }
  return response;
}
