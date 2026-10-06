# Changelog

What changed in each release, written for people who use bupsy. Add to "Unreleased" in the same
PR as the change; the release moves it under a version.

## Unreleased

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
