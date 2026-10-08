/// The page another device opens to use Bupsy: a phone, another Mac. Served by `RemoteAccess` from this Mac,
/// to the person's own devices over Tailscale. One self-contained page, no external requests.
///
/// Everything lives in one string so there is nothing to bundle, copy into the app, or fall out of step with
/// the server: the page and the routes it calls ship in the same build. It loads no fonts, scripts or images
/// from anywhere else, which keeps it working on a tailnet with no internet and leaks nothing about what the
/// person is doing to a third party.
///
/// It polls rather than holding a socket open. A phone sleeps, changes networks and drops off Tailscale far
/// more often than a desktop does, and a poll simply carries on afterwards where a socket would need
/// reconnecting. Polling stops while the page is hidden, so an idle phone costs the Mac nothing.
///
/// Server text only ever reaches the page as text nodes, never as markup: a bot that quotes HTML shows it.
enum RemoteWebApp {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-title" content="Bupsy">
    <meta name="apple-mobile-web-app-status-bar-style" content="default">
    <meta name="theme-color" content="#fafafa" media="(prefers-color-scheme: light)">
    <meta name="theme-color" content="#101010" media="(prefers-color-scheme: dark)">
    <meta name="color-scheme" content="light dark">
    <meta name="referrer" content="no-referrer">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/icon.png">
    <title>Bupsy</title>
    <style>
      /* Tokens match the Mac app's Palette, so the two feel like one product. */
      :root {
        color-scheme: light dark;
        --bg: #ffffff;
        --sidebar: #fafafa;
        --card: #f5f5f5;
        --card-hover: #ebebeb;
        --fg: #0a0a0a;
        --muted: #737373;
        --primary: #d76abf;
        --on-primary: #fafafa;
        --success: #007c32;
        --warning: #a25700;
        --destructive: #ce1c12;
        --border: rgba(0, 0, 0, .08);
        --you: rgba(215, 106, 191, .14);
        --tint: rgba(215, 106, 191, .07);
        --tint-border: rgba(215, 106, 191, .45);
        --recess: rgba(0, 0, 0, .055);
        --shadow: 0 8px 30px rgba(0, 0, 0, .12);
        --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        --mono: ui-monospace, "SF Mono", Menlo, monospace;
        --safe-top: env(safe-area-inset-top, 0px);
        --safe-bottom: env(safe-area-inset-bottom, 0px);
        --safe-left: env(safe-area-inset-left, 0px);
        --safe-right: env(safe-area-inset-right, 0px);
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #202020;
          --sidebar: #101010;
          --card: #292929;
          --card-hover: #343434;
          --fg: #fafafa;
          --muted: #a1a1a1;
          --primary: #e075c8;
          --on-primary: #171717;
          --success: #33b75f;
          --warning: #de9016;
          --destructive: #ff756e;
          --border: rgba(255, 255, 255, .10);
          --you: rgba(224, 117, 200, .26);
          --tint: rgba(224, 117, 200, .10);
          --tint-border: rgba(224, 117, 200, .50);
          --recess: rgba(0, 0, 0, .35);
          --shadow: 0 8px 30px rgba(0, 0, 0, .5);
        }
      }

      * { box-sizing: border-box; }
      [hidden] { display: none !important; }
      html, body { height: 100%; margin: 0; }
      body {
        background: var(--bg);
        color: var(--fg);
        font: 16px/1.4 var(--font);
        -webkit-text-size-adjust: 100%;
        -webkit-font-smoothing: antialiased;
        -webkit-tap-highlight-color: transparent;
        overscroll-behavior: none;
      }
      button { font: inherit; color: inherit; }
      :focus { outline: none; }
      :focus-visible { outline: 2px solid var(--primary); outline-offset: 2px; }
      .visually-hidden {
        position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
        overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0;
      }

      /* ---------- Buttons ---------- */
      .btn {
        appearance: none; border: 0; border-radius: 10px; padding: 9px 16px; min-height: 40px;
        font-weight: 600; font-size: 15px; cursor: pointer; line-height: 1.2;
        transition: filter .15s, background-color .15s, opacity .15s;
      }
      .btn.primary { background: var(--primary); color: var(--on-primary); }
      .btn.primary:hover:not(:disabled) { filter: brightness(1.06); }
      .btn.secondary { background: var(--card-hover); color: var(--fg); }
      .btn.secondary:hover:not(:disabled) { filter: brightness(.97); }
      .btn:disabled { opacity: .5; cursor: default; }
      .btn.wide { width: 100%; }
      .icon-btn {
        appearance: none; border: 0; background: transparent; width: 40px; height: 40px;
        border-radius: 10px; display: inline-grid; place-items: center; cursor: pointer; flex: none;
      }
      .icon-btn:hover { background: var(--card); }
      .icon-btn svg { width: 22px; height: 22px; }

      /* ---------- Wordmark ---------- */
      .wordmark {
        margin: 0; font-weight: 800; letter-spacing: -.025em; font-size: 22px; line-height: 1.1;
        display: inline-flex; align-items: center; gap: 8px;
      }
      .wordmark::before {
        content: ""; width: .5em; height: .5em; border-radius: 50%; background: var(--primary); flex: none;
      }
      .wordmark.large { font-size: 36px; }

      /* ---------- Full-screen states (pairing, connecting) ---------- */
      .screen {
        position: fixed; inset: 0; display: flex; align-items: center; justify-content: center; overflow: auto;
        padding: calc(24px + var(--safe-top)) calc(20px + var(--safe-right)) calc(24px + var(--safe-bottom)) calc(20px + var(--safe-left));
        background: var(--sidebar);
      }
      .screen-card { width: min(380px, 100%); display: flex; flex-direction: column; align-items: center; text-align: center; gap: 14px; }
      .screen-card .lead { margin: 0 0 10px; color: var(--muted); font-size: 17px; }
      .code-input {
        width: 100%; font: 600 30px/1.2 var(--mono); letter-spacing: .32em; text-indent: .32em; text-align: center;
        text-transform: uppercase; padding: 14px 10px; border-radius: 14px; border: 1px solid var(--border);
        background: var(--card); color: var(--fg);
      }
      .code-input::placeholder { color: var(--muted); opacity: .45; }
      .code-input:focus-visible { outline: 2px solid var(--primary); outline-offset: 0; }
      .error { margin: 0; min-height: 1.4em; color: var(--destructive); font-size: 14px; }
      .hint { margin: 6px 0 0; color: var(--muted); font-size: 13px; }

      /* ---------- App shell ---------- */
      .app { position: fixed; inset: 0; display: grid; grid-template-columns: 300px 1fr; overflow: hidden; }
      .pane { min-width: 0; min-height: 0; display: flex; flex-direction: column; }
      .list-pane { background: var(--sidebar); border-right: 1px solid var(--border); padding-left: var(--safe-left); }
      .chat-pane { background: var(--bg); padding-right: var(--safe-right); position: relative; }

      /* Narrow screens: the list is the home screen and a chat slides over it. */
      @media (max-width: 759px) {
        .app { display: block; }
        .pane { position: absolute; inset: 0; }
        .list-pane { border-right: 0; padding-right: var(--safe-right); transition: transform .3s cubic-bezier(.2, .8, .2, 1); }
        .chat-pane {
          padding-left: var(--safe-left); z-index: 1; transform: translateX(100%); box-shadow: var(--shadow);
          transition: transform .3s cubic-bezier(.2, .8, .2, 1);
        }
        .app.chat-open .chat-pane { transform: none; }
        .app.chat-open .list-pane { transform: translateX(-25%); }
        .chat-empty { display: none !important; }
      }
      @media (min-width: 760px) {
        .back { display: none !important; }
      }

      /* ---------- Bot list ---------- */
      .list-header {
        display: flex; align-items: flex-start; justify-content: space-between; gap: 10px;
        padding: calc(16px + var(--safe-top)) 16px 10px 20px;
      }
      .mac-name { margin: 4px 0 0; color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
      .pill {
        appearance: none; border: 0; cursor: pointer; flex: none; margin-top: 1px;
        display: inline-flex; align-items: center; gap: 6px; padding: 5px 10px; border-radius: 999px;
        background: var(--you); color: var(--fg); font-size: 13px; font-weight: 600; white-space: nowrap;
      }
      .pill::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--primary); }
      .bot-list {
        flex: 1; overflow-y: auto; -webkit-overflow-scrolling: touch;
        padding: 2px 0 calc(16px + var(--safe-bottom));
      }
      .section {
        margin: 0; padding: 16px 20px 6px; font-size: 12px; font-weight: 600; color: var(--muted);
        text-transform: uppercase; letter-spacing: .05em;
      }
      .row {
        appearance: none; display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 12px;
        width: calc(100% - 16px); max-width: calc(100% - 16px); min-width: 0; overflow: hidden; margin: 0 8px 2px; padding: 10px; border: 0; border-radius: 12px;
        background: transparent; text-align: left; cursor: pointer; transition: background-color .12s;
      }
      .row:hover { background: var(--card); }
      .row.selected { background: var(--card-hover); }
      .row-text { min-width: 0; overflow: hidden; display: flex; flex-direction: column; gap: 2px; }
      .row-top { display: flex; align-items: center; gap: 6px; min-width: 0; }
      .row-name { font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .row.unread .row-name { font-weight: 700; }
      .row-preview { display: block; max-width: 100%; font-size: 14px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .row.unread .row-preview { color: var(--fg); }
      .tag {
        flex: none; font-size: 11px; font-weight: 600; line-height: 1.5; padding: 0 6px; border-radius: 6px;
        background: var(--card-hover); color: var(--muted);
      }
      .row.selected .tag { background: var(--bg); }
      .row-status { display: inline-flex; align-items: center; justify-content: flex-end; min-width: 12px; }
      .needs-dot { width: 10px; height: 10px; border-radius: 50%; background: var(--primary); }
      .list-empty { margin: 30px 24px; color: var(--muted); text-align: center; font-size: 14px; }

      .avatar {
        --size: 40px;
        width: var(--size); height: var(--size); border-radius: 50%; flex: none;
        display: inline-grid; place-items: center; background: var(--muted); color: #fff;
        font-weight: 700; font-size: calc(var(--size) * .42); line-height: 1; text-shadow: 0 1px 1px rgba(0, 0, 0, .18);
        user-select: none;
      }

      /* The "working" indicator: three dots that breathe. */
      .dots { display: inline-flex; gap: 3px; align-items: center; }
      .dots span { width: 5px; height: 5px; border-radius: 50%; background: var(--muted); animation: breathe 1.2s infinite ease-in-out; }
      .dots span:nth-child(2) { animation-delay: .15s; }
      .dots span:nth-child(3) { animation-delay: .3s; }
      @keyframes breathe { 0%, 80%, 100% { opacity: .25; transform: scale(.85); } 40% { opacity: 1; transform: scale(1); } }

      /* ---------- Chat ---------- */
      .chat-empty { flex: 1; display: grid; place-items: center; color: var(--muted); font-size: 15px; padding: 24px; text-align: center; }
      .chat { flex: 1; display: flex; flex-direction: column; min-height: 0; }
      .chat-header {
        display: flex; align-items: center; gap: 10px; flex: none;
        padding: calc(10px + var(--safe-top)) 14px 10px 10px; border-bottom: 1px solid var(--border); background: var(--bg);
      }
      @media (min-width: 760px) { .chat-header { padding-left: 18px; } }
      .chat-title { min-width: 0; flex: 1; }
      .chat-title h2 { margin: 0; font-size: 16px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .chat-status { margin: 1px 0 0; font-size: 13px; color: var(--muted); min-height: 1.2em; }
      .chat-status.waiting { color: var(--primary); font-weight: 600; }
      .stop { display: inline-flex; align-items: center; gap: 7px; padding: 7px 12px; min-height: 34px; font-size: 14px; }
      .stop::before { content: ""; width: 9px; height: 9px; border-radius: 2px; background: currentColor; }

      .messages {
        flex: 1; min-height: 0; overflow-y: auto; -webkit-overflow-scrolling: touch; overscroll-behavior: contain;
        position: relative; padding: 8px 12px 12px;
      }
      .thread, .messages > .note, .messages > .typing { max-width: 860px; margin-left: auto; margin-right: auto; }
      .entry { display: flex; flex-direction: column; }

      .day { align-self: center; margin: 14px 0 6px; }
      .day span { display: inline-block; font-size: 12px; font-weight: 500; color: var(--muted); background: var(--card); padding: 3px 10px; border-radius: 999px; }

      .msg { display: flex; margin-top: 2px; }
      .msg.first { margin-top: 10px; }
      .msg.you { justify-content: flex-end; }
      .bubble {
        max-width: min(80%, 640px); min-width: 0; padding: 6px 10px 7px; border-radius: 16px;
        background: var(--card); overflow-wrap: anywhere; word-break: normal;
      }
      .msg.you .bubble { background: var(--you); }
      .msg.first.you .bubble { border-top-right-radius: 5px; }
      .msg.first.bot .bubble { border-top-left-radius: 5px; }
      .who { font-size: 13px; font-weight: 600; margin-bottom: 1px; color: var(--muted); }
      .plain { white-space: pre-wrap; }
      .meta { float: right; margin: 7px 0 -4px 12px; font-size: 11px; line-height: 1.2; color: var(--muted); white-space: nowrap; }
      .meta.block { float: none; display: block; text-align: right; margin: 2px 0 0; }

      /* Markdown inside a bot bubble. */
      .md > :first-child { margin-top: 0; }
      .md > :last-child { margin-bottom: 0; }
      .md p { margin: 0 0 8px; }
      .md .h { font-weight: 700; margin: 10px 0 4px; }
      .md .h1 { font-size: 1.2em; }
      .md .h2 { font-size: 1.1em; }
      .md ul, .md ol { margin: 4px 0 8px; padding-left: 1.4em; }
      .md li { margin: 2px 0; }
      .md li.nested { margin-left: 1.2em; list-style-type: circle; }
      .md blockquote { margin: 6px 0; padding: 2px 0 2px 10px; border-left: 3px solid var(--card-hover); color: var(--muted); }
      .md hr { border: 0; border-top: 1px solid var(--border); margin: 10px 0; }
      .md a { color: var(--primary); text-decoration: underline; text-underline-offset: 2px; }
      .md code { font: .87em/1.4 var(--mono); background: var(--recess); padding: 1px 5px; border-radius: 5px; }
      .md pre {
        margin: 6px 0 8px; padding: 10px 12px; border-radius: 10px; background: var(--recess);
        overflow-x: auto; -webkit-overflow-scrolling: touch; white-space: pre; overflow-wrap: normal;
      }
      .md pre code { background: none; padding: 0; font-size: 13px; line-height: 1.45; }
      .table-wrap { overflow-x: auto; -webkit-overflow-scrolling: touch; margin: 6px 0 8px; }
      .md table { border-collapse: collapse; font-size: 14px; overflow-wrap: normal; }
      .md th, .md td { padding: 5px 10px; border-bottom: 1px solid var(--border); text-align: left; vertical-align: top; }
      .md th { font-weight: 600; border-bottom-color: var(--muted); white-space: nowrap; }
      .md tr:last-child td { border-bottom: 0; }

      /* Quiet lines: tool steps, decided cards, notes. */
      .line {
        display: flex; align-items: baseline; gap: 6px; min-width: 0; max-width: 100%;
        margin-top: 4px; padding: 1px 4px; font-size: 13px; color: var(--muted);
      }
      .line::before { content: ""; flex: none; width: 5px; height: 5px; border-radius: 50%; background: currentColor; opacity: .55; transform: translateY(-2px); }
      .line .verb { flex: none; }
      .line .target { font: 12px/1.4 var(--mono); min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .line.failed { color: var(--destructive); }
      .line.allowed::before { background: var(--success); opacity: 1; }
      .line.denied::before { background: var(--destructive); opacity: 1; }
      .note { margin: 10px auto; max-width: 85%; text-align: center; font-size: 12.5px; color: var(--muted); white-space: pre-wrap; overflow-wrap: anywhere; }
      .note.failure { color: var(--destructive); }

      /* Cards that wait on the person: approvals and questions. */
      .card {
        margin: 10px 0 4px; max-width: min(100%, 560px); padding: 12px 14px; border-radius: 14px;
        border: 1px solid var(--tint-border); background: var(--tint);
      }
      .card-title { margin: 0 0 8px; font-weight: 600; font-size: 15px; overflow-wrap: anywhere; }
      .summary {
        margin: 0; padding: 8px 10px; border-radius: 10px; background: var(--recess);
        font: 13px/1.45 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere;
        max-height: calc(8 * 1.45em + 16px); overflow: hidden;
      }
      .summary.clipped { -webkit-mask-image: linear-gradient(#000 65%, transparent); mask-image: linear-gradient(#000 65%, transparent); }
      .summary.expanded { max-height: none; -webkit-mask-image: none; mask-image: none; }
      .more { appearance: none; border: 0; background: none; color: var(--primary); font-size: 13px; font-weight: 600; padding: 4px 0; cursor: pointer; }
      .card-reason { margin: 8px 0 0; color: var(--muted); font-size: 14px; white-space: pre-wrap; overflow-wrap: anywhere; }
      .actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 12px; flex-wrap: wrap; }
      .options { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
      .options .btn { min-width: 64px; }
      .answer-row { display: flex; gap: 8px; margin-top: 10px; }
      .answer-row input {
        flex: 1; min-width: 0; font: 16px var(--font); padding: 8px 12px; border-radius: 10px;
        border: 1px solid var(--border); background: var(--bg); color: var(--fg);
      }

      .typing .bubble { padding: 11px 12px; }

      /* ---------- Composer ---------- */
      .composer {
        flex: none; display: flex; align-items: flex-end; gap: 8px;
        padding: 8px 12px calc(8px + var(--safe-bottom)); border-top: 1px solid var(--border); background: var(--bg);
      }
      .composer-inner { flex: 1; display: flex; align-items: flex-end; gap: 8px; max-width: 860px; margin: 0 auto; }
      .composer textarea {
        flex: 1; min-width: 0; resize: none; display: block; margin: 0;
        min-height: 40px; max-height: 160px; padding: 9px 14px; border-radius: 20px;
        border: 1px solid var(--border); background: var(--card); color: var(--fg); font: 16px/1.35 var(--font);
      }
      .composer textarea::placeholder { color: var(--muted); }
      .composer textarea:focus-visible { outline: 2px solid var(--primary); outline-offset: 0; }
      .send {
        appearance: none; border: 0; flex: none; width: 40px; height: 40px; border-radius: 50%;
        display: grid; place-items: center; background: var(--primary); color: var(--on-primary); cursor: pointer;
        transition: opacity .15s, transform .1s;
      }
      .send:active:not(:disabled) { transform: scale(.94); }
      .send:disabled { opacity: .35; cursor: default; }
      .send svg { width: 20px; height: 20px; }

      /* ---------- Offline banner and toast ---------- */
      .offline {
        position: fixed; z-index: 10; left: 50%; top: calc(8px + var(--safe-top)); transform: translateX(-50%);
        display: inline-flex; align-items: center; gap: 8px; max-width: calc(100% - 32px);
        padding: 6px 12px; border-radius: 999px; background: var(--card); border: 1px solid var(--border);
        box-shadow: var(--shadow); color: var(--fg); font-size: 13px; font-weight: 500;
      }
      .offline::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--warning); flex: none; }
      .toast {
        position: fixed; z-index: 11; left: 50%; bottom: calc(76px + var(--safe-bottom)); transform: translate(-50%, 8px);
        max-width: min(420px, calc(100% - 32px)); padding: 10px 14px; border-radius: 12px;
        background: var(--fg); color: var(--bg); font-size: 14px; box-shadow: var(--shadow);
        opacity: 0; transition: opacity .2s, transform .2s; pointer-events: none; text-align: center;
      }
      .toast.show { opacity: 1; transform: translate(-50%, 0); }

      @media (prefers-reduced-motion: reduce) {
        *, *::before, *::after { transition: none !important; animation: none !important; }
      }
    </style>
    </head>
    <body>

    <div id="connecting" class="screen" hidden>
      <div class="screen-card">
        <h1 class="wordmark large">Bupsy</h1>
        <p id="connecting-message" class="lead">Connecting to your Mac…</p>
        <button id="retry" class="btn secondary" type="button" hidden>Try again</button>
      </div>
    </div>

    <div id="pair" class="screen" hidden>
      <form id="pair-form" class="screen-card" novalidate>
        <h1 class="wordmark large">Bupsy</h1>
        <p class="lead">Pair this device with Bupsy on your Mac</p>
        <label for="pair-code" class="visually-hidden">Pairing code</label>
        <input id="pair-code" class="code-input" type="text" inputmode="text" maxlength="6" placeholder="ABC123"
               autocomplete="one-time-code" autocapitalize="characters" autocorrect="off" spellcheck="false"
               aria-describedby="pair-hint pair-error">
        <button id="pair-button" class="btn primary wide" type="submit">Pair</button>
        <p id="pair-error" class="error" role="alert"></p>
        <p id="pair-hint" class="hint">On your Mac: Settings → Use from other devices → Pair a device</p>
      </form>
    </div>

    <div id="app" class="app" hidden>
      <aside id="list-pane" class="pane list-pane" aria-label="Bots">
        <header class="list-header">
          <div>
            <h1 class="wordmark">Bupsy</h1>
            <p id="mac-name" class="mac-name"></p>
          </div>
          <button id="waiting-pill" class="pill" type="button" hidden></button>
        </header>
        <nav id="bot-list" class="bot-list" aria-label="Your bots"></nav>
      </aside>

      <main id="chat-pane" class="pane chat-pane">
        <div id="chat-empty" class="chat-empty">Pick a bot to chat with.</div>
        <section id="chat" class="chat" hidden aria-labelledby="chat-name">
          <header class="chat-header">
            <button id="back" class="icon-btn back" type="button" aria-label="Back to bots">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>
            </button>
            <span id="chat-avatar"></span>
            <div class="chat-title">
              <h2 id="chat-name"></h2>
              <p id="chat-status" class="chat-status" aria-live="polite"></p>
            </div>
            <button id="stop" class="btn secondary stop" type="button" hidden>Stop</button>
          </header>
          <div id="messages" class="messages" role="log" aria-label="Messages">
            <div id="thread" class="thread"></div>
            <p id="chat-none" class="note" hidden>No messages yet. Say hello.</p>
            <div id="typing" class="msg bot first typing" hidden aria-hidden="true">
              <div class="bubble"><span class="dots"><span></span><span></span><span></span></span></div>
            </div>
          </div>
          <form id="composer-form" class="composer">
            <div class="composer-inner">
              <label for="composer" class="visually-hidden">Message</label>
              <textarea id="composer" rows="1" placeholder="Message"></textarea>
              <button id="send" class="send" type="submit" aria-label="Send" disabled>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5"/><path d="M5 12l7-7 7 7"/></svg>
              </button>
            </div>
          </form>
        </section>
      </main>
    </div>

    <div id="offline" class="offline" role="status" hidden>Can't reach your Mac. Retrying…</div>
    <div id="toast" class="toast" role="alert"></div>

    <script>
    (() => {
      "use strict";

      // ===================================================================================
      // Small DOM helpers. Server text only ever reaches the page through textContent or
      // text nodes, never through innerHTML, so nothing it says can become markup.
      // ===================================================================================

      const byId = (id) => document.getElementById(id);

      function el(tag, className, text) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text != null) node.textContent = String(text);
        return node;
      }

      function button(label, className, onClick) {
        const node = el("button", className, label);
        node.type = "button";
        node.addEventListener("click", onClick);
        return node;
      }

      /** Accepts only plain hex colours, so a style property can never receive anything else. */
      function safeColour(value) {
        return typeof value === "string" && /^#[0-9a-f]{3,8}$/i.test(value) ? value : null;
      }

      const enc = encodeURIComponent;

      const ui = {
        connecting: byId("connecting"),
        connectingMessage: byId("connecting-message"),
        retry: byId("retry"),
        pair: byId("pair"),
        pairForm: byId("pair-form"),
        pairCode: byId("pair-code"),
        pairButton: byId("pair-button"),
        pairError: byId("pair-error"),
        app: byId("app"),
        listPane: byId("list-pane"),
        macName: byId("mac-name"),
        waitingPill: byId("waiting-pill"),
        botList: byId("bot-list"),
        chatPane: byId("chat-pane"),
        chatEmpty: byId("chat-empty"),
        chat: byId("chat"),
        back: byId("back"),
        chatAvatar: byId("chat-avatar"),
        chatName: byId("chat-name"),
        chatStatus: byId("chat-status"),
        stop: byId("stop"),
        messages: byId("messages"),
        thread: byId("thread"),
        chatNone: byId("chat-none"),
        typing: byId("typing"),
        composerForm: byId("composer-form"),
        composer: byId("composer"),
        send: byId("send"),
        offline: byId("offline"),
        toast: byId("toast"),
      };

      const wideQuery = window.matchMedia("(min-width: 760px)");
      const touchQuery = window.matchMedia("(hover: none) and (pointer: coarse)");

      const state = {
        paired: false,
        mac: "",
        bots: [],
        waiting: 0,
        openId: null,
        openBot: null,
        chatToken: 0,          // bumps whenever the open chat changes, so late responses are dropped
        nodes: new Map(),      // entry id -> { sig, node }: lets a poll reuse the DOM it already built
        drafts: new Map(),     // bot id -> unsent text, so switching bots never loses a half-typed message
        scrollOnNextRender: false,
        nearBottom: true,
        pushedHistory: false,
        sending: false,
        autoPairTried: false,
      };

      // ===================================================================================
      // Network
      // ===================================================================================

      class AuthError extends Error {}
      class NetworkError extends Error {}
      class ServerError extends Error {
        constructor(message, status) { super(message); this.status = status; }
      }

      const UNREACHABLE = "Couldn't reach your Mac. Is it awake?";

      async function api(method, path, body) {
        const options = { method, credentials: "same-origin", cache: "no-store", headers: { Accept: "application/json" } };
        if (body !== undefined) {
          options.headers["Content-Type"] = "application/json";
          options.body = JSON.stringify(body);
        }
        let response;
        try {
          response = await fetch(path, options);
        } catch (_) {
          throw new NetworkError(UNREACHABLE);
        }
        let data = null;
        try { data = await response.json(); } catch (_) { data = null; }
        const message = data && typeof data.error === "string" && data.error ? data.error : null;
        if (response.status === 401) throw new AuthError(message || "This device isn't paired.");
        if (!response.ok) {
          // A proxy in front of the Mac answers 502/504 when the app itself is unreachable.
          if (response.status >= 500 && !message) throw new NetworkError(UNREACHABLE);
          throw new ServerError(message || `Something went wrong (${response.status}).`, response.status);
        }
        return data || {};
      }

      const botPath = (id, rest = "") => `/api/bots/${enc(id)}${rest}`;

      // ===================================================================================
      // Polling. Plain timers rather than a socket: it survives the Mac sleeping, the phone
      // switching networks, and Tailscale reconnecting, with nothing to re-establish.
      // ===================================================================================

      const poll = { listGen: 0, chatGen: 0, listTimer: 0, chatTimer: 0 };

      function startPolling() {
        stopPolling();
        if (!state.paired || document.hidden) return;
        listLoop(++poll.listGen);
        if (state.openId) chatLoop(++poll.chatGen);
      }

      function stopPolling() {
        poll.listGen++;
        poll.chatGen++;
        clearTimeout(poll.listTimer);
        clearTimeout(poll.chatTimer);
      }

      function restartChatPolling() {
        poll.chatGen++;
        clearTimeout(poll.chatTimer);
        if (state.paired && !document.hidden && state.openId) chatLoop(poll.chatGen);
      }

      async function listLoop(gen) {
        await refreshBots();
        if (gen !== poll.listGen) return;
        poll.listTimer = setTimeout(() => listLoop(gen), state.openId ? 6000 : 3000);
      }

      async function chatLoop(gen) {
        await refreshChat();
        if (gen !== poll.chatGen || !state.openId) return;
        poll.chatTimer = setTimeout(() => chatLoop(gen), 1500);
      }

      function handlePollError(error) {
        if (error instanceof AuthError) { unpaired(); return; }
        setOnline(false);
      }

      function handleActionError(error) {
        if (error instanceof AuthError) { unpaired(); return; }
        if (error instanceof NetworkError) setOnline(false);
        toast(error.message || UNREACHABLE);
      }

      function setOnline(online) {
        ui.offline.hidden = online;
      }

      async function refreshBots() {
        try {
          const data = await api("GET", "/api/bots");
          setOnline(true);
          state.bots = Array.isArray(data.bots) ? data.bots.filter((b) => b && typeof b.id === "string") : [];
          state.waiting = Math.max(0, Number(data.waiting) || 0);
          if (state.openId) {
            const fresh = findBot(state.openId);
            if (fresh) { state.openBot = fresh; renderChatHeader(); }
          }
          renderList();
        } catch (error) {
          handlePollError(error);
        }
      }

      async function refreshChat() {
        const id = state.openId;
        const token = state.chatToken;
        if (!id) return;
        try {
          const data = await api("GET", botPath(id, "/messages"));
          if (id !== state.openId || token !== state.chatToken) return;
          setOnline(true);
          if (data.bot && data.bot.id === id) {
            state.openBot = data.bot;
            replaceBot(data.bot);
            renderChatHeader();
          }
          renderEntries(Array.isArray(data.entries) ? data.entries : []);
        } catch (error) {
          if (id !== state.openId) return;
          if (error instanceof ServerError && error.status === 404) {
            toast("That bot isn't on your Mac any more.");
            closeChat();
            return;
          }
          handlePollError(error);
        }
      }

      function findBot(id) {
        return state.bots.find((b) => b.id === id) || null;
      }

      function replaceBot(bot) {
        const index = state.bots.findIndex((b) => b.id === bot.id);
        if (index >= 0) { state.bots[index] = bot; renderList(); }
      }

      // ===================================================================================
      // Screens: connecting, pairing, the app.
      // ===================================================================================

      let connectTimer = 0;

      async function boot() {
        clearTimeout(connectTimer);
        try {
          const session = await api("GET", "/api/session");
          state.mac = typeof session.mac === "string" ? session.mac : "";
          showApp();
          return true;
        } catch (error) {
          if (error instanceof AuthError) { showPair(); return false; }
          showConnecting(error.message || UNREACHABLE);
          return false;
        }
      }

      function showScreen(which) {
        ui.connecting.hidden = which !== "connecting";
        ui.pair.hidden = which !== "pair";
        ui.app.hidden = which !== "app";
      }

      function showConnecting(message) {
        state.paired = false;
        stopPolling();
        showScreen("connecting");
        ui.connectingMessage.textContent = message;
        ui.retry.hidden = false;
        // Keep trying quietly: the usual cause is a sleeping Mac, which will wake on its own.
        connectTimer = setTimeout(() => { if (!document.hidden) boot(); }, 5000);
      }

      function showPair(message) {
        state.paired = false;
        stopPolling();
        state.openId = null;
        state.openBot = null;
        resetChat();
        showScreen("pair");
        ui.pairError.textContent = message || "";
        const code = codeFromURL();
        if (code && !ui.pairCode.value) ui.pairCode.value = code;
        if (code && !state.autoPairTried) {
          state.autoPairTried = true;
          pair(code);
        } else if (!touchQuery.matches) {
          ui.pairCode.focus();
        }
      }

      /** A device can be removed on the Mac at any time; the next request says so with a 401. */
      function unpaired() {
        if (!state.paired) return;
        showPair("This device isn't paired any more. Make a new code on your Mac to pair it again.");
      }

      function showApp() {
        state.paired = true;
        showScreen("app");
        ui.macName.textContent = state.mac;
        applyLayout();
        const fromHash = botIdFromHash();
        if (fromHash && fromHash !== state.openId) openChat(fromHash, { fromHistory: true });
        startPolling();
      }

      // ----- Pairing -----

      function normaliseCode(value) {
        return String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
      }

      function codeFromURL() {
        try {
          return normaliseCode(new URLSearchParams(window.location.search).get("code"));
        } catch (_) {
          return "";
        }
      }

      function clearCodeFromURL() {
        try {
          const url = new URL(window.location.href);
          if (!url.searchParams.has("code")) return;
          url.searchParams.delete("code");
          history.replaceState(history.state, "", url.pathname + url.search + url.hash);
        } catch (_) { /* Older browsers: leaving the code in the address bar is harmless. */ }
      }

      /** What the Mac's device list will call this device. Guessed from the user agent, which is all a page can see. */
      function deviceName() {
        const ua = navigator.userAgent || "";
        if (/iPhone|iPod/.test(ua)) return "iPhone";
        if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return "iPad";
        if (/Android/.test(ua)) return /Mobile/.test(ua) ? "Android phone" : "Android tablet";
        if (/Macintosh|Mac OS X/.test(ua)) return "Mac";
        if (/Windows/.test(ua)) return "Windows PC";
        if (/CrOS/.test(ua)) return "Chromebook";
        if (/Linux/.test(ua)) return "Linux computer";
        return "Browser";
      }

      async function pair(rawCode) {
        const code = normaliseCode(rawCode);
        ui.pairCode.value = code;
        if (code.length !== 6) {
          ui.pairError.textContent = "Enter the 6-character code from your Mac.";
          return;
        }
        ui.pairButton.disabled = true;
        ui.pairButton.textContent = "Pairing…";
        ui.pairError.textContent = "";
        try {
          await api("POST", "/api/pair", { code, name: deviceName() });
          clearCodeFromURL();
          ui.pairCode.value = "";
          const signedIn = await boot();
          if (!signedIn && !ui.pair.hidden) {
            ui.pairError.textContent = "Paired, but this browser didn't keep the sign-in. Allow cookies for this page and try again.";
          }
        } catch (error) {
          // A bad code may come back as a 401 or a 4xx; either way the server's words are the useful part.
          ui.pairError.textContent = error.message || "That didn't work. Try again.";
        } finally {
          ui.pairButton.disabled = false;
          ui.pairButton.textContent = "Pair";
        }
      }

      // ===================================================================================
      // Layout: one column on a phone, two on anything wider.
      // ===================================================================================

      function applyLayout() {
        const wide = wideQuery.matches;
        const open = Boolean(state.openId);
        ui.app.classList.toggle("chat-open", open);
        // On a phone the hidden pane is only slid off screen, so make it unreachable by keyboard and screen readers too.
        ui.listPane.inert = !wide && open;
        ui.chatPane.inert = !wide && !open;
        ui.chatEmpty.hidden = open;
        // On a phone the chat stays rendered while it slides away; on a wide screen the empty state takes its place.
        ui.chat.hidden = wide ? !open : !open && !state.openBot;
      }

      function botIdFromHash() {
        const match = /^#bot\/(.+)$/.exec(window.location.hash || "");
        if (!match) return null;
        try { return decodeURIComponent(match[1]); } catch (_) { return null; }
      }

      function setHash(id, push) {
        const url = window.location.pathname + window.location.search + (id ? `#bot/${enc(id)}` : "");
        if (push) history.pushState({ bot: id }, "", url);
        else history.replaceState(id ? { bot: id } : null, "", url);
      }

      // ===================================================================================
      // Bot list
      // ===================================================================================

      let listSignature = "";

      function renderList() {
        const signature = JSON.stringify([state.bots, state.waiting, state.openId]);
        if (signature === listSignature) return;
        listSignature = signature;

        renderWaiting();

        // Rebuilding drops focus, so remember which row had it and give it back.
        const focusedId = document.activeElement && ui.botList.contains(document.activeElement)
          ? document.activeElement.dataset.id : null;

        const fragment = document.createDocumentFragment();
        if (state.bots.length === 0) {
          fragment.append(el("p", "list-empty", "No bots yet. Make one in Bupsy on your Mac."));
        }
        for (const [section, bots] of groupBySection(state.bots)) {
          if (bots.length === 0) continue;
          if (section) fragment.append(el("h2", "section", section));
          for (const bot of bots) fragment.append(botRow(bot));
        }
        ui.botList.replaceChildren(fragment);

        if (focusedId) {
          const row = Array.from(ui.botList.querySelectorAll(".row")).find((r) => r.dataset.id === focusedId);
          if (row) row.focus({ preventScroll: true });
        }
      }

      function renderWaiting() {
        const n = state.waiting;
        ui.waitingPill.hidden = n <= 0;
        ui.waitingPill.textContent = `${n} waiting on you`;
        document.title = n > 0 ? `(${n}) Bupsy` : "Bupsy";
      }

      /** Server order is kept; sections appear in the order they first show up, with unsectioned bots first. */
      function groupBySection(bots) {
        const groups = new Map([[null, []]]);
        for (const bot of bots) {
          const key = typeof bot.section === "string" && bot.section ? bot.section : null;
          if (!groups.has(key)) groups.set(key, []);
          groups.get(key).push(bot);
        }
        return groups;
      }

      function botRow(bot) {
        const row = el("button", "row");
        row.type = "button";
        row.dataset.id = bot.id;
        if (bot.unread) row.classList.add("unread");
        if (bot.id === state.openId) {
          row.classList.add("selected");
          row.setAttribute("aria-current", "true");
        }

        const text = el("span", "row-text");
        const top = el("span", "row-top");
        top.append(el("span", "row-name", bot.name || "Bot"));
        if (bot.role) top.append(el("span", "tag", bot.role));
        text.append(top, el("span", "row-preview", previewFor(bot)));

        row.append(avatar(bot, 42), text, statusMark(bot));
        row.setAttribute("aria-label", rowLabel(bot));
        row.addEventListener("click", () => openChat(bot.id));
        return row;
      }

      function previewFor(bot) {
        if (bot.preview) return bot.preview;
        return bot.running ? "Working…" : "Nothing yet";
      }

      function statusText(bot) {
        if (bot.needsYou) return "Waiting on you";
        if (bot.running) return "Working…";
        return "";
      }

      function rowLabel(bot) {
        const parts = [bot.name || "Bot"];
        if (bot.role) parts.push(bot.role);
        const status = statusText(bot);
        if (status) parts.push(status);
        if (bot.unread) parts.push("unread");
        if (bot.preview) parts.push(bot.preview);
        return parts.join(", ");
      }

      function statusMark(bot) {
        const wrap = el("span", "row-status");
        wrap.setAttribute("aria-hidden", "true");
        if (bot.needsYou) {
          wrap.append(el("span", "needs-dot"));
        } else if (bot.running) {
          wrap.append(workingDots());
        }
        return wrap;
      }

      function workingDots() {
        const dots = el("span", "dots");
        dots.append(el("span"), el("span"), el("span"));
        return dots;
      }

      function avatar(bot, size) {
        const name = String((bot && bot.name) || "?").trim();
        const node = el("span", "avatar", (Array.from(name)[0] || "?").toUpperCase());
        node.setAttribute("aria-hidden", "true");
        node.style.setProperty("--size", `${size}px`);
        const colour = safeColour(bot && bot.colour);
        if (colour) node.style.background = colour;
        return node;
      }

      // ===================================================================================
      // Opening and closing a chat
      // ===================================================================================

      function openChat(id, { fromHistory = false } = {}) {
        if (!state.paired) return;
        if (state.openId === id) { applyLayout(); return; }
        saveDraft();
        resetChat();
        state.openId = id;
        state.openBot = findBot(id) || { id, name: "", running: false, needsYou: false };
        state.chatToken++;
        state.scrollOnNextRender = true;

        ui.composer.value = state.drafts.get(id) || "";
        autoGrow();
        updateSend();
        renderChatHeader();
        renderList();
        applyLayout();

        if (!fromHistory) {
          const push = !wideQuery.matches;
          setHash(id, push);
          state.pushedHistory = push;
        }
        restartChatPolling();
        // A phone keyboard popping up on every open is unwelcome; on a desktop, typing straight away is the point.
        if (!touchQuery.matches) ui.composer.focus({ preventScroll: true });
      }

      function closeChat({ fromHistory = false } = {}) {
        if (!state.openId) return;
        saveDraft();
        state.openId = null;
        state.chatToken++;
        poll.chatGen++;
        clearTimeout(poll.chatTimer);
        if (!fromHistory) setHash(null, false);
        state.pushedHistory = false;
        renderList();
        applyLayout();
        const row = ui.botList.querySelector(".row.selected, .row");
        if (row && !touchQuery.matches) row.focus({ preventScroll: true });
      }

      /** Forgets the rendered thread, so the next chat starts clean. */
      function resetChat() {
        state.nodes.clear();
        ui.thread.replaceChildren();
        ui.chatNone.hidden = true;
        ui.typing.hidden = true;
        state.nearBottom = true;
      }

      function goBack() {
        // If we pushed the history entry, popping it keeps the browser's own back button in step.
        if (state.pushedHistory && history.state && history.state.bot === state.openId) history.back();
        else closeChat();
      }

      function saveDraft() {
        if (!state.openId) return;
        const text = ui.composer.value;
        if (text.trim()) state.drafts.set(state.openId, text);
        else state.drafts.delete(state.openId);
      }

      function renderChatHeader() {
        const bot = state.openBot;
        if (!bot) return;
        const keepBottom = isNearBottom();
        ui.chatAvatar.replaceChildren(avatar(bot, 36));
        ui.chatName.textContent = bot.name || "";
        const status = statusText(bot);
        if (ui.chatStatus.textContent !== status) ui.chatStatus.textContent = status;
        ui.chatStatus.classList.toggle("waiting", Boolean(bot.needsYou));
        ui.stop.hidden = !bot.running;
        ui.composer.placeholder = bot.name ? `Message ${bot.name}` : "Message";
        ui.typing.hidden = !bot.running || Boolean(bot.needsYou);
        if (keepBottom) scrollToBottom();
      }

      // ===================================================================================
      // Messages: diffed by entry id, so a poll that brings nothing new touches nothing.
      // ===================================================================================

      function isNearBottom() {
        const m = ui.messages;
        return m.scrollHeight - m.scrollTop - m.clientHeight < 120;
      }

      function scrollToBottom() {
        ui.messages.scrollTop = ui.messages.scrollHeight;
        state.nearBottom = true;
      }

      /** Remembers which entry sits at the top of the view, so trimming old entries doesn't move what the person is reading. */
      function captureAnchor() {
        const top = ui.messages.scrollTop;
        for (const child of ui.thread.children) {
          if (child.offsetTop + child.offsetHeight > top) return { node: child, offset: child.offsetTop - top };
        }
        return null;
      }

      function restoreAnchor(anchor) {
        if (anchor && anchor.node.isConnected) ui.messages.scrollTop = anchor.node.offsetTop - anchor.offset;
      }

      /** Bubbles from the same speaker run together; anything else starts a new run. */
      function runKey(entry) {
        if (!entry) return null;
        if (entry.kind === "you") return "you";
        if (entry.kind === "bot") return "bot";
        if (entry.kind === "from") return `from:${entry.author || ""}`;
        return null;
      }

      function renderEntries(entries) {
        const stickToBottom = state.scrollOnNextRender || isNearBottom();
        const anchor = stickToBottom ? null : captureAnchor();
        const bot = state.openBot || {};
        const context = `${bot.name || ""}|${bot.colour || ""}`;

        const seen = new Set();
        const desired = [];
        let previous = null;
        for (const entry of entries) {
          if (!entry || typeof entry.id !== "string" || seen.has(entry.id)) continue;
          seen.add(entry.id);
          const showDay = !previous || dayKey(entry.at) !== dayKey(previous.at);
          const key = runKey(entry);
          const first = showDay || key === null || key !== runKey(previous);
          const authorColour = entry.kind === "from" ? colourForAuthor(entry.author) : "";
          const sig = `${JSON.stringify(entry)}|${showDay}|${first}|${context}|${authorColour}`;
          let cached = state.nodes.get(entry.id);
          if (!cached || cached.sig !== sig) {
            cached = { sig, node: renderEntry(entry, { showDay, first }) };
            state.nodes.set(entry.id, cached);
          }
          desired.push(cached.node);
          previous = entry;
        }
        for (const id of Array.from(state.nodes.keys())) {
          if (!seen.has(id)) state.nodes.delete(id);
        }

        reconcile(ui.thread, desired);
        ui.chatNone.hidden = desired.length > 0;
        measureSummaries();

        if (stickToBottom) scrollToBottom();
        else restoreAnchor(anchor);
        state.scrollOnNextRender = false;
      }

      /** Puts `nodes` in order under `parent`, moving only what's out of place. */
      function reconcile(parent, nodes) {
        nodes.forEach((node, index) => {
          const current = parent.children[index];
          if (current !== node) parent.insertBefore(node, current || null);
        });
        while (parent.children.length > nodes.length) parent.lastElementChild.remove();
      }

      function renderEntry(entry, options) {
        const wrap = el("div", "entry");
        wrap.dataset.id = entry.id;
        if (options.showDay) wrap.append(dayChip(entry.at));
        const render = RENDERERS[entry.kind] || renderUnknown;
        const body = render(entry, options);
        if (body) wrap.append(body);
        return wrap;
      }

      const RENDERERS = {
        you: renderYou,
        bot: renderBotReply,
        from: renderFrom,
        tool: renderTool,
        approval: renderApproval,
        question: renderQuestion,
        note: (entry) => el("p", "note", entry.text || ""),
        failure: (entry) => el("p", "note failure", entry.text || "Something went wrong."),
      };

      function renderUnknown(entry) {
        return entry.text ? el("p", "note", entry.text) : null;
      }

      // ----- Bubbles -----

      function bubbleRow(side, first) {
        const row = el("div", `msg ${side}${first ? " first" : ""}`);
        const bubble = el("div", "bubble");
        row.append(bubble);
        return { row, bubble };
      }

      function renderYou(entry, { first }) {
        const { row, bubble } = bubbleRow("you", first);
        const content = el("div", "plain", entry.text || "");
        bubble.append(content);
        appendTime(bubble, content, entry.at);
        return row;
      }

      function renderBotReply(entry, { first }) {
        const bot = state.openBot || {};
        return speakerBubble(entry, first, bot.name || "", safeColour(bot.colour));
      }

      function renderFrom(entry, { first }) {
        return speakerBubble(entry, first, entry.author || "Another bot", colourForAuthor(entry.author));
      }

      function speakerBubble(entry, first, name, colour) {
        const { row, bubble } = bubbleRow("bot", first);
        if (first && name) {
          const who = el("div", "who", name);
          if (colour) who.style.color = colour;
          bubble.append(who);
        }
        const content = renderMarkdown(entry.text || "");
        bubble.append(content);
        appendTime(bubble, content, entry.at);
        return row;
      }

      function colourForAuthor(author) {
        const match = state.bots.find((b) => b.name === author);
        return (match && safeColour(match.colour)) || null;
      }

      /** WhatsApp-style: the time tucks into the end of the last line when it fits, else drops below. */
      function appendTime(bubble, content, at) {
        const time = formatTime(at);
        if (!time) return;
        const meta = el("span", "meta", time);
        const last = content.lastElementChild;
        if (content.classList.contains("plain")) content.append(meta);
        else if (last && last.tagName === "P") last.append(meta);
        else { meta.classList.add("block"); bubble.append(meta); }
      }

      // ----- Quiet lines -----

      function quietLine(className, verb, target, title) {
        const line = el("div", `line ${className || ""}`.trim());
        if (verb) line.append(el("span", "verb", verb));
        if (target) {
          const t = el("span", "target", target);
          t.title = title || target;
          line.append(t);
        }
        return line;
      }

      function renderTool(entry) {
        const tool = entry.tool || {};
        const line = quietLine(tool.failed ? "failed" : "", tool.verb || "used a tool", tool.target || "");
        if (tool.failed) line.append(el("span", "verb", "· failed"));
        return line;
      }

      // ----- Approvals -----

      const APPROVAL_VERBS = new Map([
        ["Bash", "run a command"],
        ["Edit", "edit a file"],
        ["MultiEdit", "edit a file"],
        ["Write", "write a file"],
        ["NotebookEdit", "edit a notebook"],
        ["Read", "read a file"],
        ["Glob", "look through files"],
        ["Grep", "search files"],
        ["WebFetch", "open a web page"],
        ["WebSearch", "search the web"],
      ]);

      function approvalVerb(tool) {
        if (!tool) return "do something";
        if (APPROVAL_VERBS.has(tool)) return APPROVAL_VERBS.get(tool);
        const mcp = /^mcp__.+?__(.+)$/.exec(tool);
        return `use ${mcp ? mcp[1].replace(/_/g, " ") : tool}`;
      }

      function renderApproval(entry) {
        const approval = entry.approval || {};
        if (approval.decided != null) return decidedApproval(approval);

        const card = el("div", "card");
        card.setAttribute("role", "group");
        const botName = (state.openBot && state.openBot.name) || "Your bot";
        const title = el("p", "card-title", `${botName} wants to ${approvalVerb(approval.tool)}`);
        card.append(title);
        card.setAttribute("aria-label", title.textContent);

        if (approval.summary) {
          const summary = el("pre", "summary", approval.summary);
          card.append(summary);
        }
        if (approval.reason) card.append(el("p", "card-reason", approval.reason));

        const actions = el("div", "actions");
        const deny = button("Deny", "btn secondary", () => decide(approval.id, false, [deny, allow]));
        const allow = button("Allow", "btn primary", () => decide(approval.id, true, [deny, allow]));
        actions.append(deny, allow);
        card.append(actions);
        return card;
      }

      function decidedApproval(approval) {
        const summary = approval.summary || "";
        switch (approval.decided) {
          case "allowed": return quietLine("allowed", "Allowed:", summary);
          case "alwaysAllowed": return quietLine("allowed", "Always allowed:", summary);
          case "denied": return quietLine("denied", summary ? "Denied:" : "Denied", summary);
          case "expired": return quietLine("", "Timed out. Nothing ran.", "");
          default: return quietLine("", String(approval.decided), summary);
        }
      }

      /** Long commands fade out after eight lines, with a way to read the rest. */
      function measureSummaries() {
        window.requestAnimationFrame(() => {
          for (const summary of ui.thread.querySelectorAll(".summary:not([data-measured])")) {
            if (!summary.clientHeight) continue; // not laid out yet; try on the next render
            summary.dataset.measured = "1";
            if (summary.scrollHeight <= summary.clientHeight + 2) continue;
            summary.classList.add("clipped");
            const more = button("Show all", "more", () => {
              summary.classList.add("expanded");
              more.remove();
            });
            summary.after(more);
          }
        });
      }

      async function decide(approvalId, allow, buttons) {
        const botId = state.openId;
        if (!botId || !approvalId) return;
        setDisabled(buttons, true);
        try {
          await api("POST", botPath(botId, `/approvals/${enc(approvalId)}`), { allow });
          await refreshChat();
          refreshBots();
          // If the card is somehow still undecided a while later, let the person try again.
          setTimeout(() => setDisabled(buttons, false), 8000);
        } catch (error) {
          setDisabled(buttons, false);
          handleActionError(error);
        }
      }

      function setDisabled(nodes, disabled) {
        for (const node of nodes) if (node) node.disabled = disabled;
      }

      // ----- Questions -----

      function renderQuestion(entry) {
        const q = entry.question || {};
        if (q.answer != null) return quietLine("", "You answered:", String(q.answer), q.question || "");

        const card = el("div", "card");
        card.setAttribute("role", "group");
        const title = el("p", "card-title", q.question || "Your bot has a question");
        card.append(title);
        card.setAttribute("aria-label", title.textContent);

        const options = Array.isArray(q.options) ? q.options.filter((o) => typeof o === "string" && o) : [];
        const controls = [];
        if (options.length) {
          const wrap = el("div", "options");
          for (const option of options) {
            const choice = button(option, "btn secondary", () => answer(q.id, option, controls));
            controls.push(choice);
            wrap.append(choice);
          }
          card.append(wrap);
        } else {
          // No options offered: let the person type an answer.
          const row = el("div", "answer-row");
          const input = el("input");
          input.type = "text";
          input.placeholder = "Your answer";
          input.setAttribute("aria-label", "Your answer");
          const submit = button("Answer", "btn primary", () => {
            if (input.value.trim()) answer(q.id, input.value.trim(), controls);
          });
          input.addEventListener("keydown", (event) => {
            if (event.key === "Enter" && !event.isComposing) { event.preventDefault(); submit.click(); }
          });
          controls.push(input, submit);
          row.append(input, submit);
          card.append(row);
        }
        return card;
      }

      async function answer(questionId, value, controls) {
        const botId = state.openId;
        if (!botId || !questionId) return;
        setDisabled(controls, true);
        try {
          await api("POST", botPath(botId, `/questions/${enc(questionId)}`), { answer: value });
          await refreshChat();
          refreshBots();
          setTimeout(() => setDisabled(controls, false), 8000);
        } catch (error) {
          setDisabled(controls, false);
          handleActionError(error);
        }
      }

      // ----- Times and days -----

      const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

      function parseDate(at) {
        if (!at) return null;
        const date = new Date(at);
        return Number.isNaN(date.getTime()) ? null : date;
      }

      function formatTime(at) {
        const date = parseDate(at);
        return date ? timeFormat.format(date) : "";
      }

      function dayKey(at) {
        const date = parseDate(at);
        return date ? `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}` : "";
      }

      function dayChip(at) {
        const chip = el("div", "day");
        chip.append(el("span", null, dayLabel(at)));
        return chip;
      }

      function dayLabel(at) {
        const date = parseDate(at);
        if (!date) return "Earlier";
        const startOf = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
        const days = Math.round((startOf(new Date()) - startOf(date)) / 86400000);
        if (days === 0) return "Today";
        if (days === 1) return "Yesterday";
        if (days > 1 && days < 7) return date.toLocaleDateString(undefined, { weekday: "long" });
        const sameYear = date.getFullYear() === new Date().getFullYear();
        return date.toLocaleDateString(undefined, { day: "numeric", month: "short", year: sameYear ? undefined : "numeric" });
      }

      // ===================================================================================
      // Markdown: a small, safe subset. Everything is built as DOM nodes from plain text,
      // so a bot quoting HTML shows the HTML rather than running it.
      // ===================================================================================

      const FENCE = /^\s{0,3}(`{3,}|~{3,})\s*([\w+#.-]*)\s*$/;
      const HEADING = /^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/;
      const HR = /^\s{0,3}([-*_])(\s*\1){2,}\s*$/;
      const QUOTE = /^\s{0,3}>\s?(.*)$/;
      const LIST_ITEM = /^(\s*)([-*+•]|\d{1,9}[.)])\s+(.*)$/;
      const TABLE_RULE = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
      // Groups: 1-2 code, 3-4 [link](url), 5 bare url, 6 **bold**, 7 __bold__, 8 *italic*, 9 _italic_.
      const INLINE = /(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)|\[([^\]\n]+)\]\(\s*(https?:\/\/[^\s)]+)\s*\)|(https?:\/\/[^\s<>"']*[^\s<>"'.,;:!?)\]}])|\*\*(?=\S)([\s\S]*?\S)\*\*|__(?=\S)([\s\S]*?\S)__|\*(?=[^\s*])([^*\n]*?[^\s*])\*|\b_(?=[^\s_])([^_\n]*?[^\s_])_\b/;

      function renderMarkdown(source) {
        const root = el("div", "md");
        const lines = String(source).replace(/\r\n?/g, "\n").split("\n");
        let i = 0;
        while (i < lines.length) {
          const line = lines[i];
          let match;
          if (!line.trim()) { i++; continue; }
          if ((match = FENCE.exec(line))) { i = codeBlock(lines, i, match[1], root); continue; }
          if (isTableStart(lines, i)) { i = table(lines, i, root); continue; }
          if ((match = HEADING.exec(line))) {
            const heading = el("p", `h h${match[1].length}`);
            inline(match[2], heading);
            root.append(heading);
            i++;
            continue;
          }
          if (HR.test(line)) { root.append(el("hr")); i++; continue; }
          if (QUOTE.test(line)) { i = quote(lines, i, root); continue; }
          if (LIST_ITEM.test(line)) { i = list(lines, i, root); continue; }
          i = paragraph(lines, i, root);
        }
        return root;
      }

      function startsBlock(lines, i) {
        const line = lines[i];
        return FENCE.test(line) || HEADING.test(line) || HR.test(line) || QUOTE.test(line)
          || LIST_ITEM.test(line) || isTableStart(lines, i);
      }

      function paragraph(lines, start, root) {
        const p = el("p");
        let i = start;
        while (i < lines.length && lines[i].trim() && (i === start || !startsBlock(lines, i))) {
          if (i > start) p.append(el("br"));
          inline(lines[i].trim(), p);
          i++;
        }
        root.append(p);
        return i;
      }

      function codeBlock(lines, start, fence, root) {
        const body = [];
        let i = start + 1;
        while (i < lines.length) {
          const t = lines[i].trim();
          if (t.length >= fence.length && t === fence[0].repeat(t.length)) break;
          body.push(lines[i]);
          i++;
        }
        const pre = el("pre");
        pre.append(el("code", null, body.join("\n")));
        root.append(pre);
        return i + 1; // past the closing fence, or past the end if the bot never closed it
      }

      function quote(lines, start, root) {
        const body = [];
        let i = start;
        let match;
        while (i < lines.length && (match = QUOTE.exec(lines[i]))) { body.push(match[1]); i++; }
        const block = el("blockquote");
        block.append(...Array.from(renderMarkdown(body.join("\n")).childNodes));
        root.append(block);
        return i;
      }

      function list(lines, start, root) {
        const head = LIST_ITEM.exec(lines[start]);
        const ordered = /\d/.test(head[2]);
        const baseIndent = head[1].length;
        const listEl = el(ordered ? "ol" : "ul");
        if (ordered) {
          const first = parseInt(head[2], 10);
          if (first !== 1) listEl.start = first;
        }
        let item = null;
        let i = start;
        while (i < lines.length) {
          const line = lines[i];
          const match = HR.test(line) ? null : LIST_ITEM.exec(line);
          if (match) {
            const nested = match[1].length > baseIndent + 1;
            if (!nested && /\d/.test(match[2]) !== ordered) break; // a different kind of list starts here
            item = el("li", nested ? "nested" : null);
            inline(match[3], item);
            listEl.append(item);
            i++;
            continue;
          }
          if (!line.trim()) {
            // A blank line only continues the list when another item follows it.
            if (i + 1 < lines.length && LIST_ITEM.test(lines[i + 1])) { i++; continue; }
            break;
          }
          if (item && /^\s+\S/.test(line)) {
            item.append(el("br"));
            inline(line.trim(), item);
            i++;
            continue;
          }
          break;
        }
        root.append(listEl);
        return i;
      }

      function isTableStart(lines, i) {
        return i + 1 < lines.length && lines[i].includes("|") && lines[i + 1].includes("|")
          && lines[i + 1].includes("-") && TABLE_RULE.test(lines[i + 1]);
      }

      function splitRow(line) {
        let s = line.trim();
        if (s.startsWith("|")) s = s.slice(1);
        if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
        const cells = [];
        let current = "";
        for (let k = 0; k < s.length; k++) {
          const ch = s[k];
          if (ch === "\\" && s[k + 1] === "|") { current += "|"; k++; continue; }
          if (ch === "|") { cells.push(current.trim()); current = ""; continue; }
          current += ch;
        }
        cells.push(current.trim());
        return cells;
      }

      function table(lines, start, root) {
        const header = splitRow(lines[start]);
        const aligns = splitRow(lines[start + 1]).map((c) => {
          const left = c.startsWith(":");
          const right = c.endsWith(":");
          return left && right ? "center" : right ? "right" : "";
        });
        const tableEl = el("table");
        const thead = el("thead");
        const headRow = el("tr");
        header.forEach((cell, k) => headRow.append(tableCell("th", cell, aligns[k])));
        thead.append(headRow);
        const tbody = el("tbody");
        let i = start + 2;
        while (i < lines.length && lines[i].trim() && lines[i].includes("|")) {
          const cells = splitRow(lines[i]);
          const row = el("tr");
          for (let k = 0; k < header.length; k++) row.append(tableCell("td", cells[k] || "", aligns[k]));
          tbody.append(row);
          i++;
        }
        tableEl.append(thead, tbody);
        const wrap = el("div", "table-wrap");
        wrap.append(tableEl);
        root.append(wrap);
        return i;
      }

      function tableCell(tag, text, align) {
        const cell = el(tag);
        if (align) cell.style.textAlign = align;
        inline(text, cell);
        return cell;
      }

      function inline(text, parent, depth = 0) {
        if (depth > 4) { parent.append(text); return; }
        const re = new RegExp(INLINE.source, "g");
        let last = 0;
        let m;
        while ((m = re.exec(text))) {
          if (m.index > last) parent.append(text.slice(last, m.index));
          if (m[1]) {
            let code = m[2];
            if (code.length > 2 && code.startsWith(" ") && code.endsWith(" ")) code = code.slice(1, -1);
            parent.append(el("code", null, code));
          } else if (m[3] !== undefined) {
            parent.append(link(m[4], m[3]));
          } else if (m[5] !== undefined) {
            parent.append(link(m[5], null));
          } else if (m[6] !== undefined || m[7] !== undefined) {
            const strong = el("strong");
            inline(m[6] !== undefined ? m[6] : m[7], strong, depth + 1);
            parent.append(strong);
          } else {
            const em = el("em");
            inline(m[8] !== undefined ? m[8] : m[9], em, depth + 1);
            parent.append(em);
          }
          last = re.lastIndex;
        }
        if (last < text.length) parent.append(text.slice(last));
      }

      /** Only http and https become links; anything else stays as the text it was. */
      function link(raw, label) {
        let href = null;
        try {
          const url = new URL(raw);
          if (url.protocol === "http:" || url.protocol === "https:") href = url.href;
        } catch (_) { href = null; }
        const text = label != null ? label : raw;
        if (!href) return document.createTextNode(label != null ? `${label} (${raw})` : raw);
        const a = el("a", null, text);
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        return a;
      }

      // ===================================================================================
      // Composer
      // ===================================================================================

      function autoGrow() {
        const c = ui.composer;
        c.style.height = "auto";
        c.style.height = `${Math.min(c.scrollHeight + 2, 160)}px`;
      }

      function updateSend() {
        ui.send.disabled = state.sending || !ui.composer.value.trim();
      }

      async function send() {
        const id = state.openId;
        const text = ui.composer.value.trim();
        if (!id || !text || state.sending) return;
        state.sending = true;
        ui.composer.value = "";
        state.drafts.delete(id);
        autoGrow();
        updateSend();
        try {
          await api("POST", botPath(id, "/messages"), { text });
          if (state.openId === id) {
            state.scrollOnNextRender = true;
            await refreshChat();
          }
          refreshBots();
        } catch (error) {
          // Give the words back rather than lose them.
          if (state.openId === id && !ui.composer.value) { ui.composer.value = text; autoGrow(); }
          else if (state.openId !== id && !state.drafts.has(id)) state.drafts.set(id, text);
          handleActionError(error);
        } finally {
          state.sending = false;
          updateSend();
        }
      }

      async function stopBot() {
        const id = state.openId;
        if (!id) return;
        ui.stop.disabled = true;
        try {
          await api("POST", botPath(id, "/stop"));
          await refreshChat();
          refreshBots();
        } catch (error) {
          handleActionError(error);
        } finally {
          ui.stop.disabled = false;
        }
      }

      // ===================================================================================
      // Toast
      // ===================================================================================

      let toastTimer = 0;

      function toast(message) {
        ui.toast.textContent = message;
        ui.toast.classList.add("show");
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => ui.toast.classList.remove("show"), 4000);
      }

      // ===================================================================================
      // Wiring
      // ===================================================================================

      function wire() {
        ui.pairForm.addEventListener("submit", (event) => {
          event.preventDefault();
          pair(ui.pairCode.value);
        });
        ui.pairCode.addEventListener("input", () => {
          const cleaned = normaliseCode(ui.pairCode.value);
          if (cleaned !== ui.pairCode.value) ui.pairCode.value = cleaned;
          ui.pairError.textContent = "";
        });
        ui.retry.addEventListener("click", () => {
          ui.connectingMessage.textContent = "Connecting to your Mac…";
          boot();
        });

        ui.waitingPill.addEventListener("click", () => {
          const next = state.bots.find((b) => b.needsYou && b.id !== state.openId) || state.bots.find((b) => b.needsYou);
          if (next) openChat(next.id);
        });
        ui.back.addEventListener("click", goBack);
        ui.stop.addEventListener("click", stopBot);

        ui.composerForm.addEventListener("submit", (event) => {
          event.preventDefault();
          send();
        });
        ui.composer.addEventListener("input", () => { autoGrow(); updateSend(); });
        ui.composer.addEventListener("keydown", (event) => {
          // On a keyboard, Enter sends and Shift+Enter breaks the line. On a phone, Return is a newline and the button sends.
          if (event.key !== "Enter" || event.shiftKey || event.isComposing || touchQuery.matches) return;
          event.preventDefault();
          send();
        });

        ui.messages.addEventListener("scroll", () => { state.nearBottom = isNearBottom(); }, { passive: true });
        // The keyboard opening or the composer growing shrinks the view; stay pinned to the newest message if we were there.
        if ("ResizeObserver" in window) {
          new ResizeObserver(() => { if (state.nearBottom) scrollToBottom(); }).observe(ui.messages);
        }

        window.addEventListener("popstate", () => {
          if (!state.paired) return;
          const id = botIdFromHash();
          state.pushedHistory = false;
          if (id) openChat(id, { fromHistory: true });
          else closeChat({ fromHistory: true });
        });

        const onLayoutChange = () => applyLayout();
        if (wideQuery.addEventListener) wideQuery.addEventListener("change", onLayoutChange);
        else if (wideQuery.addListener) wideQuery.addListener(onLayoutChange);

        // Polling stops while the page is hidden, and catches up the moment it's back.
        document.addEventListener("visibilitychange", () => {
          if (document.hidden) { stopPolling(); return; }
          if (state.paired) startPolling();
          else if (!ui.connecting.hidden) boot();
        });
        window.addEventListener("pageshow", (event) => { if (event.persisted && state.paired) startPolling(); });
        window.addEventListener("online", () => { if (state.paired) startPolling(); else if (!ui.connecting.hidden) boot(); });
      }

      wire();
      showScreen("connecting");
      boot();
    })();
    </script>
    </body>
    </html>
    """#
}
