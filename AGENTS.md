# Working on bupsy.si: notes for AI agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) first; its rules (no vendor credentials, clean room,
Swift 6 strict concurrency, no telemetry) apply to agents too. This file adds how work is
**tracked**, so the people running the project see where things stand without asking. Keep the
trackers updated as part of the work, without being asked; a change is not finished until its
issue, the project board and the CRM say so.

## Where work is tracked

- **GitHub issues** in `xocketlabs/bupsy.si`: every piece of build work (app, engine, site, CI,
  releases, bugs) is an issue. Labels:
  - milestone `M1`–`M6` (build track; `M6` is current),
  - `type:feature`, `type:task`, `type:bug`,
  - `area:app`, `area:engine`, `area:site`, `area:ci`, `area:release`, `area:design`.
- **Milestone trackers**: one issue per milestone labelled `tracker` (M1–M5 are #153–#157,
  closed; M6 is #158). A milestone's issues hang under its tracker as **sub-issues**, and GitHub
  works out the milestone's % from them.
- **Project board**: https://github.com/orgs/xocketlabs/projects/10 (private). Fields: **Status**
  (Todo / In Progress / Done), **Priority** (P0–P2), **Track** (Build / Growth / Ops), **Area**,
  **Effort** (S / M / L). Growth and Ops work lives there as draft items, not public issues, so
  marketing plans stay out of this public repo.
- **Vansh CRM** (the `vansh-crm` MCP server, project `bupsy`): the same work by track
  (build / growth / ops) → milestone → big tasks, each task linking to its GitHub issue or PR.
  This is what Vansh reads day to day. Use the `pm_*` tools; read `pm_board` first so you update
  rather than duplicate, and always pass a stable `ref` (`bupsy-…`). An agent without a token
  asks Vansh for one rather than skipping the update.

## How a piece of work moves

1. **Issue.** Find the issue, or open one (title says the outcome; body says the problem and
   "Done when"). Label it with its milestone, type and area, add it as a sub-issue of the
   milestone's tracker, add it to the project with Priority, Track, Area and Effort, and add or
   update the matching CRM task with `link` set to the issue.
2. **Start.** Set the project Status to **In Progress** and the CRM task to `doing`.
3. **Branch.** Work on your own branch (`feat/…`, `fix/…`, `docs/…`, `site/…`). Never push to
   `main`; it is protected.
4. **PR.** Open a PR whose description starts with `Closes #<issue>` (one line per issue), and
   say why, not just what. Several small, finished branches may go out as one batch PR, listing
   every issue it closes.
5. **Merge.** When it merges, GitHub closes the issues, the board moves them to Done and the
   tracker's % goes up. Then set the CRM task to `done` with `link` set to the PR. When the last
   sub-issue of a milestone closes, close its tracker; the CRM milestone moves to done on its own.
6. **Found something else?** A bug or follow-up found along the way gets its own issue right
   away (labelled, under the right tracker, on the board), so nothing is forgotten.

Short version: **issue → In Progress → branch → PR "Closes #…" → merge → issue closes → % goes
up → CRM task done.**

## When the plan changes

- **A new milestone**: add the label (`M7`…), a tracker issue labelled `tracker`, its project
  item, and the CRM milestone (`pm_save_milestone`, same number and title) in one go.
- **Something needs Vansh** (an account, a key, a decision, a look at a video): assign the issue
  or CRM task to Vansh and say exactly what's needed. Don't wait silently.
- **Words**: Bupsy is "source-available", never "open source" (PolyForm Shield 1.0.0; 0.2.0 was
  BUSL 1.1).
