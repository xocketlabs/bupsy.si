#!/usr/bin/env python3
"""Builds the site's text pages (about, privacy, developers, contact, 404) from their Markdown.

Each page's .md file in site/ is the source: agents are served it as is (Accept: text/markdown),
and this turns it into the HTML page people see, in the landing page's type and colours. Edit the
.md, run this, commit both. Supports what those pages use: #/## headings, paragraphs, - lists,
**bold**, `code`, [links](url), and <!-- contact-form --> for the contact page's form.
"""
import html
import re
from pathlib import Path

SITE = Path(__file__).resolve().parent.parent / "site"
ORIGIN = "https://bupsy.si"

PAGES = {
    "about": ("/about", "About Bupsy: AI bots for your Mac, by Xocket Labs",
              "Why Bupsy exists, what makes it different, and who makes it. A Mac app for a team of AI bots on your own Claude Code or Codex subscription."),
    "privacy": ("/privacy", "Privacy · Bupsy",
                "What the Bupsy website and app keep: Clarity analytics on the landing page, no app telemetry, and your AI sign-in stays with the CLI."),
    "developers": ("/developers", "Bupsy for developers: MCP server, download API, Markdown for agents",
                   "Bupsy's public MCP server, download API and Markdown for agents, and how the Bupsy Mac app works with MCP, Claude Code and Codex."),
    "contact": ("/contact", "Contact Bupsy",
                "Write to the people who make Bupsy: getting it running, questions, your data, press and security. We answer by email."),
    "404": ("/404", "Page not found · Bupsy", "There is nothing at this address."),
}

CONTACT_FORM = """<form class="contact" novalidate>
  <label><span>Your name <span class="muted">(optional)</span></span><input name="name" autocomplete="name" maxlength="100"></label>
  <label>Your email<input name="email" type="email" autocomplete="email" required maxlength="254"></label>
  <label>Message<textarea name="message" rows="6" required maxlength="4000"></textarea></label>
  <input type="text" name="company" class="hp" tabindex="-1" autocomplete="off" aria-hidden="true">
  <button type="submit">Send</button>
  <p class="form-msg" role="status" aria-live="polite"></p>
</form>
<script>
  // Posts to /api/contact beside this page; the message is kept for us to answer by email.
  document.querySelector('form.contact').addEventListener('submit', async function (e) {
    e.preventDefault();
    var form = e.target, msg = form.querySelector('.form-msg'), button = form.querySelector('button');
    msg.className = 'form-msg'; button.disabled = true; msg.textContent = 'Sending…';
    try {
      var res = await fetch('/api/contact', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: form.name.value, email: form.email.value, message: form.message.value, company: form.company.value }) });
      var data = await res.json().catch(function () { return {}; });
      if (!res.ok) throw new Error(data.error || 'Something went wrong. Please try again.');
      msg.textContent = 'Sent. We’ll reply by email.'; msg.classList.add('ok'); form.reset();
    } catch (err) { msg.textContent = err.message; msg.classList.add('err'); }
    finally { button.disabled = false; }
  });
</script>"""

HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="canonical" href="{origin}{path}">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:url" content="{origin}{path}">
<meta property="og:site_name" content="Bupsy">
<meta property="og:type" content="website">
<meta property="og:image" content="{origin}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Bupsy: Your AI already has a subscription. Give it a job.">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="{origin}/og.png">
{robots}<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
{alt}<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Funnel+Display:wght@700;800&display=swap">
<style>
  :root {{ --bg:#fff; --card:#f5f5f5; --ink:#0a0a0a; --muted:#737373; --line:#e5e5e5; --primary:#d76abf;
    --display:"Funnel Display",-apple-system,BlinkMacSystemFont,system-ui,sans-serif;
    --ui:-apple-system,BlinkMacSystemFont,"SF Pro Text","Inter",system-ui,sans-serif;
    --mono:ui-monospace,"SF Mono",Menlo,monospace; color-scheme: light dark; }}
  @media (prefers-color-scheme: dark) {{ :root {{ --bg:#101010; --card:#202020; --ink:#fafafa; --muted:#a1a1a1; --line:#ffffff17; --primary:#e075c8; }} }}
  * {{ box-sizing: border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--ink); font:17px/1.65 var(--ui); -webkit-font-smoothing:antialiased; }}
  .wrap {{ max-width: 720px; margin: 0 auto; padding: 0 16px; }}
  nav {{ display:flex; align-items:center; justify-content:space-between; padding:20px 0 8px; }}
  nav a {{ color:inherit; text-decoration:none; }}
  .brand {{ display:flex; align-items:center; gap:10px; font:800 22px var(--display); letter-spacing:-.03em; }}
  .brand img {{ width:30px; height:30px; }}
  .cta {{ font-weight:600; font-size:15px; padding:9px 16px; border-radius:999px; background:var(--ink); color:var(--bg) !important; }}
  main {{ padding: 40px 0 64px; }}
  h1 {{ font: 800 clamp(36px,6vw,52px)/1.05 var(--display); letter-spacing:-.03em; margin:0 0 16px; }}
  h2 {{ font: 700 24px/1.2 var(--display); letter-spacing:-.02em; margin:40px 0 10px; }}
  .muted {{ color: var(--muted); }}
  a {{ color: var(--primary); }}
  code {{ font: 14px var(--mono); background: var(--card); padding: 2px 6px; border-radius: 6px; overflow-wrap: anywhere; }}
  ul {{ padding-left: 1.2em; }} li {{ margin: 6px 0; }}
  form.contact {{ display:grid; gap:14px; margin: 28px 0 8px; padding: 20px; background: var(--card); border-radius: 18px; }}
  form.contact label {{ display:grid; gap:6px; font-weight:600; font-size:15px; }}
  form.contact input, form.contact textarea {{ font: 16px var(--ui); color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; width: 100%; }}
  form.contact textarea {{ resize: vertical; }}
  form.contact button {{ justify-self: start; font: 600 15px var(--ui); padding: 10px 22px; border: 0; border-radius: 999px; background: var(--ink); color: var(--bg); cursor: pointer; }}
  form.contact button[disabled] {{ opacity: .6; cursor: default; }}
  .hp {{ position:absolute; left:-9999px; width:1px; height:1px; opacity:0; }}
  .form-msg {{ margin:0; font-size:15px; color: var(--muted); }} .form-msg.ok {{ color: var(--primary); font-weight:600; }} .form-msg.err {{ color:#d93b5c; }}
  footer {{ border-top:1px solid var(--line); padding:24px 0 40px; color:var(--muted); font-size:14px; display:flex; flex-wrap:wrap; gap:8px 20px; }}
  footer a {{ color: inherit; }}
</style>
</head>
<body>
<div class="wrap">
<nav aria-label="Main"><a class="brand" href="/"><img src="/favicon-32.png" alt="" width="30" height="30">Bupsy</a><a class="cta" href="/#download">Download</a></nav>
<main>
{body}
</main>
<footer><span>© 2026 Xocket Labs Inc.</span><a href="/">Home</a><a href="/about">About</a><a href="/developers">Developers</a><a href="/contact">Contact</a><a href="/privacy">Privacy</a><a href="/llms.txt">llms.txt</a><span>Not affiliated with Anthropic or OpenAI.</span></footer>
</div>
</body>
</html>
"""


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)

    def link(match):
        href = match.group(2)
        if href.startswith(ORIGIN):
            href = href[len(ORIGIN):] or "/"
        return f'<a href="{html.escape(href)}">{match.group(1)}</a>'

    return re.sub(r"\[(.+?)\]\((.+?)\)", link, text)


def to_html(markdown):
    out, in_list = [], False
    for line in markdown.strip().split("\n"):
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.strip() == "<!-- contact-form -->":
            out.append(CONTACT_FORM)
        elif line.startswith("## "):
            out.append(f'<h2 id="{slug(line[3:])}">{inline(line[3:])}</h2>')
        elif line.startswith("# "):
            out.append(f"<h1>{inline(line[2:])}</h1>")
        elif line.strip():
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main():
    for name, (path, title, desc) in PAGES.items():
        markdown = (SITE / f"{name}.md").read_text()
        page = HEAD.format(
            title=html.escape(title), desc=html.escape(desc), path=path, origin=ORIGIN,
            body=to_html(markdown),
            robots='<meta name="robots" content="noindex">\n' if name == "404" else "",
            alt="" if name == "404" else f'<link rel="alternate" type="text/markdown" href="/{name}.md">\n',
        )
        (SITE / f"{name}.html").write_text(page)
        print(f"site/{name}.html")


if __name__ == "__main__":
    main()
