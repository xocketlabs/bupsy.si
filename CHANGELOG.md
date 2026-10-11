# Changelog

What changed in each release, written for people who use bupsy. Add to "Unreleased" in the same
PR as the change; the release moves it under a version.

## Unreleased

**The website speaks to agents**
- A public MCP server at bupsy.pages.dev/mcp: agents can learn what Bupsy is, read any page, and
  join the waitlist for someone who asks. Listed in a server card and an API catalog.
- New Developers and Contact pages. The contact form's messages are kept for us to answer by email.
- llms.txt and a new agents.md say exactly when to use Bupsy and how to call it.

**New website, and a waitlist that saves**
- A new landing page on the Bupsy brand: make a bot right on the page, drag through a day on a
  roster, and see bots hand work to each other.
- Waitlist signups are now kept, in a Cloudflare D1 database beside the site. Before, the form had
  no database behind it.

**Machines are marked Beta**
- Cloud machines haven't been run end to end against boat.dev yet, so Machines now says "Beta" in
  the sidebar and on its page.

**Plan limits stay on screen**
- Your weekly and 5-hour limits now show on every bot and stay after Bupsy restarts or updates,
  instead of only on the bot that last ran, and only until the app quit. They're your account's
  limits, so whichever bot heard last updates them all.
- Usage has a "Your plan" section with each engine's limits at the top.

**Slash commands**
- Type `/` in a bot's message box for a menu of commands, narrowed as you type. Up and Down to
  choose, Return or Tab to pick, Esc to close; a click works too.
- Bupsy's own, for every bot: /model (pick from the list, or type a name), /details, /routine,
  /fresh, /stop and /help. These are done by Bupsy and never sent to the bot.
- Claude Code bots also get your own commands and skills (from `~/.claude`) and the project's
  (from `.claude` in the bot's folder), plus the built-ins that work for a bot: /compact,
  /context, /usage, /review, /security-review and /init. What /compact says, and why a command
  couldn't start, now shows in the chat; before, those left no reply at all.
- Codex bots get your custom prompts (`~/.codex/prompts`) as /prompts:name. Codex doesn't fill
  these in when it runs for a bot, so Bupsy does, with the same `$1`, `$ARGUMENTS` and `KEY=value`
  rules; the chat shows what you typed.
- A Claude command is sent on its own, without the bot's job in front of it, since Claude Code
  only runs a command at the very start of a message.
**Settings is a page in the window**
- Settings now opens in the main window, like Machines and Usage, instead of a separate window
  floating over your chats. It's under Setup in the sidebar, in the You menu, and Bupsy ›
  Settings… (Cmd ,) still goes there, reopening the window if it was closed.
- Its sections are listed on the left: Appearance, Engines, Use from other devices, Other Macs,
  Lid closed, Voice and About. Every setting is the same as before. In a narrow window the list
  shrinks to icons.
- "Link it again in Settings › Other Macs", when a bot can't move to a Mac that is no longer
  linked, now has a button that takes you there.

**Move a bot to another Mac**
- Right-click a bot (or open Runs on in its details) and choose "Move to Mac mini…" to have it
  run on another of your linked Macs from now on. A section's menu has "Move section to Mac
  mini…" for all its bots at once.
- The bot first writes itself notes on where it is up to, then carries on from them in a fresh
  chat there. Its recent messages, face, job, model, trust, routines, goals and folder watches go
  with it, and the files in its own folder are copied over (up to 200 MB). A bot working in a
  folder you chose keeps it if the other Mac has the same folder, and says so if it doesn't.
- It leaves this Mac only once the other Mac says it is set up there. If anything goes wrong on
  the way, it stays here as it was, and you're told why. A bot that is working can move once it
  finishes; a name the other Mac already has becomes "Scout 2".
- Both Macs need this version of Bupsy.
**Context window for every bot**
- Codex bots now show their context window and their plan's usage limits, read from Codex's own
  record of each turn. Before, they showed none.
- The context meter stays after Bupsy restarts or updates, until the bot's next reply, instead of
  disappearing.

**Fixed**
- "Tailscale isn't running" in Settings › Use from other devices while Tailscale was running, when
  Bupsy was opened from Finder, the Dock or at login. Tailscale's Mac app only answered Bupsy when
  Bupsy had been started from a terminal.

**Fresh chat**
- A Fresh chat button at the top of every bot's chat. The bot first writes itself short hand-off
  notes (shown in the chat), then carries on in a new conversation that starts from those notes,
  so each message costs far less than resending a long history. Earlier messages stay on screen.
- In the button's menu, "Fresh chat when a chat gets long" does this by itself for every bot once
  a chat reaches 60% of its context window, before anything queued is sent. Off until you switch
  it on.

**More for bots to do**
- Schedule: a bot can set up a routine for itself or another bot ("every day at 2pm, tell Status
  to start the day"), or remove one. It shows under the bot's Routines like any other.
- Check on each other: the bot list now says who is working, what's queued and each bot's
  routines, and a bot can read another bot's latest messages.
- Stop a bot that's stuck, switch a bot between Claude Code and Codex, and send you a
  notification when something's worth knowing.
- Still yours alone: a bot's trust level, and deleting bots.

**Bots can manage bots**
- A bot can now change another bot's job, role tag or model, start it on a fresh chat, and send
  it a first message there, with a new `manage_bot` tool. Ask your lead or status bot to "switch
  Video Producer to Sonnet and give it a fresh chat" and it does it.
- A fresh chat leaves the old conversation's context behind, so a long chat stops resending its
  whole history every turn. The earlier messages stay on screen. A bot can also start its own
  fresh chat with notes on where to pick up.
- Every change is noted in both bots' chats, naming who made it. A bot set to ask first asks you
  before changing another bot; one on Auto just does it. A bot that is working gets its fresh
  chat when it finishes.

**Continue a Claude Code chat**
- File › Continue a Claude Code Chat (Shift Cmd O), or from New chat: pick one of your recent
  conversations from VS Code or the terminal, and it becomes a bot that works in the same folder
  and remembers everything said so far. Copy and continue (the original stays untouched) or Move
  here. The bot is kept to this Mac by default.
- Bots no longer inherit the Claude Code session Bupsy was opened from: opened from inside VS
  Code's Claude, every bot's run had carried that session's id and private channel, and was saved
  as a VS Code conversation.

**Voice**
- Talk to a bot: the microphone button in any chat (Option Cmd D) turns what you say into text in
  the box, as you speak, to read over and send. It stops by itself when you stop talking.
- Hear a reply: each bot reply has a speaker button, and Settings › Voice can read new replies
  aloud in the chat you have open. Code and tables are named, not spelled out.
- Free, with no account: your Mac's own speech recognition (on this Mac whenever your language
  allows) and its system voices, including the higher-quality ones in System Settings.

**Other Macs' bots: waiting on you, and files**
- A bot on another Mac that needs you now shows in Waiting on you and the menu bar ("Lead needs
  you on Mac mini"), opening its chat.
- Files attached to a bot on another Mac are copied to that Mac, into the bot's Attachments
  folder, and the message carries the path there, so the bot can open them. Up to 50 MB each.

**Your other Macs' bots, here**
- Settings › Other Macs › Add a Mac: pick one of your Macs on Tailscale and type the code it
  shows. Its shared bots then join this Mac's sidebar in the same sections, marked with that
  Mac's icon (and its name too, when a bot here has the same name). Open one to read its chat,
  send, Allow or Deny, answer and Stop: all of it happens on its own Mac, which keeps running
  it. When that Mac is asleep or off, its bots grey out and sending waits.
- Bots set to This Mac only never appear on another Mac.

**This Mac only**
- Each bot's Details › Other devices: Shared (the default) or This Mac only. A bot kept to this
  Mac never appears on your phone or other Macs, and they can't read its chat, message it,
  approve for it or stop it: to them it does not exist.

**Bots work in the background**
- Bots, and everything they start (headless browsers, builds, video encodes), now run at
  background priority, so your own apps stay quick while bots work hard. A bot with the Mac to
  itself still gets all of it. Measured: three bots' headless Chrome took about seven cores while
  the app itself used a tenth of one.
**Bupsy for Windows and Linux, first build (in development, not downloadable yet)**
- `bupsy-desktop` runs your bots on a Windows or Linux computer and opens them in your browser,
  using the same page your phone uses with the Mac: chats, sending messages, Allow/Deny, Stop.
- It listens on this computer alone (127.0.0.1), and the browser is paired once like a phone,
  because your bots can reach this computer's own addresses too and must not answer their own
  approvals.
- Claude bots ask before acting, through the same approval hook and the same trust levels as on
  the Mac; Codex bots are held by their sandbox. There is no screen for making a bot yet:
  `bupsy-desktop --new-bot "Name" --engine codex --job "…"` makes one.

**Use Bupsy from your phone or another Mac**
- Settings › Use from other devices: one switch shares Bupsy with your own devices over Tailscale.
  Open the address on your phone (add it to the Home Screen and it opens like an app) or another
  Mac: your bots, live chats, sending messages, Allow/Deny on approvals, answering questions, Stop.
- Only your devices can reach it: Bupsy listens on this Mac alone, and Tailscale Serve (never
  Funnel) carries it over your private network with HTTPS, on its own port (8443), leaving anything
  else you serve alone. Each device is paired once with a QR code or a 6-character code; a code
  works once, for 10 minutes, and a few wrong guesses retire it. Devices can be removed any time.

**Survive sleep**
- Settings › Keep working with the lid closed: a switch that keeps this Mac running with the lid
  shut, so bots keep working. It uses Sleepless's one-time permission, so Bupsy never asks for
  your password or holds administrator rights.

**Snappier switching**
- A click on a bot answers at once in the sidebar, and the chat follows a frame later with a
  quick fade in: before, nothing on screen moved until the whole new chat was built.
- A chat draws its latest dozen items first and fills in the rest above, out of sight, a few
  at a time, pinned to where it opened. About a third faster to appear than before.
- Tables are rows of equal columns: a table with a long cell no longer draws over the messages
  after it.
- Sidebar previews, tool lines' paths and the Activity tab's run summaries no longer redo their
  work on every redraw.

**Faster switching between bots**
- A reply's measured size is remembered instead of laid out again each time SwiftUI asks, and
  a bot's folder is looked up once instead of on every tool line, so opening a chat is much
  quicker. A chat opens with its latest 80 items; Show earlier messages loads the rest.

**Tables, and a quieter idle**
- Tables in a reply render as tables: a shaded header and ruled rows, instead of lines of
  pipes and dashes.
- Resting bot faces hold still, so an idle Bupsy does no work: every moving face updated the
  whole window each frame. Faces move while a bot works, waits on you, finishes or fails.

**No more blank chats**
- A long chat could open on an empty pane with every message still there: the lazily built
  list guessed row heights and ended up scrolled past its content. A chat now shows its latest
  80 items laid out in full, with **Show earlier messages** at the top for the rest.

**Busy chats stay responsive**
- The Files panel no longer re-reads a bot's whole tool history on the main thread at every
  streamed line: it waits for a burst to settle, reads off the main thread, and looks at the
  recent history only. A long-running bot like Lead froze the window while it worked.
- Faces beside replies are still, rather than dozens redrawing 30 times a second.
- A reply's formatted text is built once, not on every redraw of the thread.

**Send now**
- A message sent while a bot is busy still waits, and now says what you can do about it:
  **Send now** stops the bot so it reads your message at once (it picks up the same
  conversation, with what it had done so far), and **Edit** takes it back into the box.
- Shift Cmd Return in the message box sends straight away while the bot works.

**Context window meter**
- The meter shows what the context actually holds: the last model call of a run, not the run's
  summed totals, which counted the context once per step (a real bot read 3.8M / 200k, 1,917%).
- The window size is the one the engine reports, so Opus 5.5 reads against 1M, not 200k.
- The bar never runs past its track.

**Bots can organise the sidebar**
- Ask a bot to group bots ("put Lead, QA Reviewer and Video Producer in Frontier & Co") and it
  can: the new `move_bots` tool files bots into a section, making the section if it is new.
  The bot's chat notes what moved and names any bot it couldn't find.
- `list_bots` now shows each bot's section.

**Chat bubbles**
- Messages sit in bubbles, so each one reads as its own: yours on the right in a pink tint, a
  bot's on the left in grey beside its face. The first bubble of a run has a small tail and the
  bot's name in its colour; every bubble has its time in the corner.
- Code blocks inside a bubble stay a clear recess in light mode.

**Run commands from a reply**
- A command in a bot's reply has a Run button beside Copy. It runs in that bot's folder through
  your login shell, and its output appears under the command, with Stop while it runs.
- Commands that delete, use sudo, pipe a download into a shell or push ask once before running.
- Only for bots on this Mac; a cloud machine's files aren't here.

**Your own browser, and replies you can copy**
- A bot on this Mac can use your own browser: Claude through Claude in Chrome, Codex through its
  browser use. Off by default; turn it on per bot under Details → Browser. Each step still goes
  through the approval gate unless you trust the bot.
- A reply selects as one piece: a drag runs across paragraphs, headings and lists, stopping only
  at code blocks, so a long answer copies whole. Copied mentions read "@Name".
- Reply puts the cursor in the message box. Hidden Reply and Copy buttons no longer take clicks.

**Security and reliability fixes from a full audit**
- Bots can no longer act as one another: each run has its own connector config and a private
  token for messages between bots, so a bot that can write files cannot speak in another's name.
- Lowering a bot's trust takes effect at once, including for its run in progress and anything
  queued. If the approval check can't be set up, the run doesn't start.
- Approvals are never offered on a command you can't see in full. Allow from a notification asks
  you to unlock, and links in replies that aren't web pages ask before opening.
- "Trusted" asks about any tool it doesn't recognise, rather than allowing it.
- Stop and Quit end the whole job, including commands it started. Deleting a bot or group stops
  its work.
- Folder watches ignore hidden files and Bupsy's own data, refuse your whole home folder, and are
  capped per hour, so a watch can't keep setting itself off.
- Group chats keep one conversation at a time, so the turn limit always holds.
- Fixed: resuming a Codex conversation failed every time; Codex usage wasn't recorded; usage
  could be counted twice after Stop; a routine could skip its first slot.

**A new look, matching the Bupsy design system**
- Every bot is now Bupsy: a gummy little character with a status light on its antenna. Pick from
  eight shapes (Bup, Blob, Pill, Cat, Bunny, Bear, Ghost, Imp) and eight colours. Its face shows
  what it is doing: idle, working, needs you, done, asleep, or something went wrong.
- Faces picked under the old shapes reset to Bup in the same colour. Pick a new one any time.
- A new app icon: Bupsy rising out of a dark tile, antenna glowing.
- Popups have a new frame, with keyboard hints on the footer. When a bot is asking, it peeks over
  the top.
- Sidebar folders are now called sections, so they no longer get mixed up with a bot's work folder.
- Empty places show a napping bot and one line on what to do next.
- Every screen restyled to match: onboarding with a scene per step, the bot creator, chats (the
  working bot peeks over the message box), Waiting on you, search, group chats, routines and goals,
  Apps, Usage, Permissions and Machines.
- New Team page: your bots by section, in columns. Move a bot with its menu or drag it across.
- New Group chats page, and the sidebar's sections now fold.
- The menu bar shows each bot's live face, and a bot that needs you can be answered right there.
- Onboarding now makes your first bot: name, face, trust and section, with a summary before you
  say hi.
- Each routine has its own page: turn it on or off, Run now, this week's runs, average time, and
  its last runs. New routine gains a Folder watch tab.
- While a bot works, the chat says what it is doing ("Running npm test"), and steps show how long
  they took. A failed reply can be retried, or its sign-in checked, from the error itself.
- Group chats pause after 3, 5 or 10 bot turns (your choice per group) and wait for you.
- A Settings window (Cmd ,) with appearance, each engine's sign-in status and About. Sign in or out
  of Claude Code and Codex from the You menu; it opens the vendor's own command in Terminal.
- Keyboard shortcuts sheet (Cmd /). Folded sidebar sections stay folded.
- Approval notifications have Allow and Deny buttons.
- Pause all bots, from the menu bar or the Bupsy menu, is now a real pause: it stops what is running
  and holds routines, goals and folder watches until you resume. Anything that falls due while
  paused is skipped, not run in a burst later. Messages you send still go. The pause lasts across
  a relaunch.
- Sections stay when their last bot leaves, and can be made empty. Delete a section from its menu;
  its bots move to Unassigned.
- What you type to a bot or a group is kept when you switch away and come back.
- Stop means stop: a bot stopped mid-reply in a group no longer posts the half-written reply or
  hands on to the next bot, and a goal check you stop is not read as an answer. Steps it was in
  the middle of show as stopped instead of spinning.
- Apps that need a key set in your shell (LINEAR_API_KEY and the like) now find it in `~/.zshrc`
  too, and the Apps page no longer stalls while it looks.

## 0.1.0 — first public build

A native Mac app for a team of AI bots that run on your own Claude Code or Codex sign-in.

**Bots**
- Make a bot in one click — it asks what it's for and names itself — or set one up yourself with
  a face, role, job, engine and model.
- Chat with streaming replies, markdown and code, attachments, reply-to and copy. Keep typing while
  a bot works; your messages are queued.
- See what a bot is doing as it works, its usage and plan limits, and every file it changed.

**Teams**
- Group chats with @mentions and a lead bot; bots hand work to each other.
- Bots can message each other, create new bots (you approve), and ask you multiple-choice questions.

**Running on their own**
- Routines on a schedule, even with bupsy closed; missed runs catch up once.
- Folder watches: a bot runs when files in a folder change.
- Standing goals checked on a schedule.

**Trust**
- Bots ask before acting: Allow, Deny, Always allow. Four trust levels, a Permissions page to take
  anything back, and a permanent log of every decision.
- bupsy never holds your engine credentials and has no server of its own.

**Apps**
- Any MCP server, and Executor — one connection to Gmail, Notion, Linear and any API, with a
  three-step setup guide.

**Look**
- Light, dark or automatic; Spotlight-style search; a plush character for every bot.

**Known limits**
- Not yet notarized by Apple: the first open needs System Settings → Privacy & Security → Open Anyway.
- Cloud machines are built but untested against boat.dev.
