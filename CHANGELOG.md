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
