# UI/UX audit, October 2026

An end-to-end read of the Mac app against the Bupsy design canvas and design system, done on branch
`design/features` (PR #91). Five reviewers covered first run (ONB), chat (CHAT), navigation and team (NAV),
automation and setup (SET) and cross-cutting design-system issues (SYS). About 190 raw findings, merged here into
one list. Where several reviewers found the same thing, all their IDs are kept.

Severity: **P0** broken, misleading or risks data. **P1** clearly off-design or real friction. **P2** polish.
Paths are under `Apps/BupsyMac/Sources` unless stated. The fixes are grouped into batches, one PR each.

---

## Batch 1: safety and data (P0 first)

- [x] **P0** Delete bot has no confirm or undo, and wipes the thread, watches and record. Sidebar menu, Team menu. RosterView.swift:74, TeamView.swift:428, AppModel.swift:2065. (ONB-1, NAV-1, SYS-1)
- [x] **P0** Delete group has no confirm; the board shows Archive. NavRail.swift:301, GroupViews.swift:260. (NAV-2)
- [x] **P0** Deleting a machine never calls boat.dev, so it keeps running and billing, while the dialog says it is removed. AppModel.swift:325, BoatAPI has no delete. (SET-1)
- [x] **P0** "Set LINEAR_API_KEY in your shell" can never work: the app reads its own env, not the login shell's. ConnectorsView.swift:237, LocalHost.swift:78. (SET-2)
- [x] **P0** A standing goal cannot be paused, edited or deleted from anywhere visible. BotPage.swift:735-775. (SET-3)
- [x] **P0** Approval cards get stuck after Stop, a crash or the 870s gate timeout: Allow/Deny do nothing, "Needs you" stays forever, and a late Allow claims success. AppModel.swift:1075,1129-1137. (CHAT-2)
- [x] **P0** The composer draft and reply-to leak between bots (and between group chats), so text can be sent to the wrong bot. BupsyApp.swift:292, :317. (CHAT-1, NAV-7)
- [x] **P1** Stop then quick send: the old run's cleanup wipes the new run's state and approval gate. AppModel.swift:955-962. (CHAT-3)
- [x] **P1** A bot question with fewer than 2 or more than 4 options, or an empty question, is silently dropped while the bot waits. Outbox.swift:84-86. (CHAT-11)
- [x] **P1** Sign out runs immediately with no confirm, and failures are silent. NavRail.swift:546, AppModel+Account.swift:155. (NAV-18)
- [x] **P1** Remove server has no confirm and also strips that server's always-allow rules from every bot. ConnectorsView.swift:241. (SET-13)
- [x] **P1** Delete folder watch, delete goal: no confirm. BotPage.swift:852, ObjectivesView.swift:104. (CHAT-32, SET-12, SYS-1)
- [x] **P2** Approval banners are never removed after answering in-app, and are matched by bot name, not id. Notifications.swift:39,156. (SET-35)
- [x] **P2** Duplicate does not copy the face or role; Shuffle face overwrites a picked face with no undo. AppModel.swift:1166. (ONB-28)

## Batch 2: getting around, window and navigation

- [x] **P1** No minimum window size. At 900 wide with details open the chat column is about 270pt; the routine page and palette overflow; onboarding (620) and routine sheets (680) are taller than a 600 window. Add 900x600 min, auto-hide or overlay details below about 1100, size-bound sheets with scrolling. (CHAT-8, SET-8, NAV-14, SYS-8)
- [x] **P1** With 0 bots the sidebar highlights Machines; deleting the last bot shows "No bot selected" instead of the empty roster. BupsyApp.swift:118, :184. (ONB-3, ONB-4, NAV-4)
- [x] **P1** "Open" from Waiting on you, Usage rows, the menu bar and notifications does nothing when that bot is already selected. Route all through `pendingDestination`. (NAV-5, SET-15)
- [x] **P1** Deleting or hiding the selected bot from Team throws you into another bot's chat. AppModel.swift:2070,1877. (NAV-6)
- [x] **P1** Menu bar "Open Bupsy" and "New bot" can't reopen a closed window; Cmd N/O shown but not wired; no scroll for long rosters. MenuBar.swift:242-259. (SET-16, SYS-7, SET-34)
- [x] **P1** Clicking a notification body does nothing; notifications carry no bot id. Notifications.swift:150. (SET-18)
- [x] **P1** Cmd N may hit File > New Window and open a second window. Replace the newItem command group. (NAV-16, SYS-26)
- [x] **P1** Several `.sheet`s chained on one view in the rail and root; the code's own comments say one gets dropped. Move to a single `.sheet(item:)` enum. NavRail.swift:82-85, BupsyApp.swift:194. (NAV-17, ONB-26)
- [x] **P1** Palette has no scrim or click-outside to close, is fixed 640 wide, and recomputes search rows about 5 times per render; group messages not searched; no "make a bot called X" on empty. BupsyApp.swift:141, StartChat.swift:35,149. (NAV-13, NAV-38)
- [x] **P1** Cmd 1 to 9 follows the model order (including hidden bots), not the sidebar order, and stops working when a section folds. NavRail.swift:400,629. (NAV-15)
- [x] **P1** With 2+ bots and no sections, loose bots render under the GROUPS header and look like groups. NavRail.swift:251-268. (NAV-3)
- [x] **P1** Hide from sidebar is one-way; hidden bots can never be unhidden. Team says "No bots yet" when all are hidden. RosterView.swift:71, TeamView.swift:87. (NAV-11, ONB-27)

## Batch 3: one truth for "needs you" and the mascot's mood

- [x] **P1** "Needs you" is computed two ways: group approvals never reach Waiting on you or the menu bar count; stuck goals make a bot wave in the menu bar but not elsewhere. Add one `mood(for:)` and use it everywhere. AppModel.swift:639-667 vs 762. (SYS-5, NAV-9)
- [x] **P1** Paused groups (turn limit) and group approvals don't appear in Waiting on you. (NAV-9, features follow-up)
- [x] **P1** Waiting on you: no way to clear a stuck goal ("Mark as handled"); "Open" should name the bot; stuck goal face should be the error mood. AttentionView.swift:167. (NAV-10)
- [x] **P1** Done, asleep and failed moods never appear for live bots, so "Last run failed" branches can never fire. Done for a few seconds after a run, asleep when paused or on a stopped machine, failed after a failed run. (SYS-6)
- [x] **P1** Every face animates at 30fps forever (sidebar, Team, menu bar, palette). Add a `still` mode and animate only the selected or non-idle bot. BotFace.swift:57. (SYS-4)
- [x] **P1** Menu bar icon is SF circles, not the Bupsy template glyph with a pink dot; no VoiceOver label. MenuBar.swift:401. (SET-17, SYS-7)
- [x] **P2** Menu bar status says only Needs you / Working / Idle; use the live status text and next routine time ("Asleep until 2am"); "Stop all bots" vs board's "Pause all bots". (SET-34, SYS-6)
- [x] **P2** At sidebar size (16 to 25pt) the antenna and status light are under 1pt and vanish; error spiral eyes smudge. Set minimum stroke and bulb size when mini; frame overhang in BotRow. BotFace.swift:143, NavRail.swift:829. (SYS-19)
- [ ] **P2** Sidebar unread dot is 6pt blue (`info`); board is 8pt pink. Decide and align. (NAV-25)

## Batch 4: chat

- [x] **P1** Cmd-Return is bound to the send button, which becomes Stop while running, so adding a follow-up kills the run. ThreadView.swift:853. (CHAT-4)
- [x] **P1** Composer loses focus on every run start and end (borderBeam swaps view identity). BotFace.swift:785. (CHAT-5)
- [x] **P1** Reading history: every new entry yanks you to the bottom. BotPage.swift:646. (CHAT-6)
- [x] **P1** Long threads are slow: non-lazy VStack, every bubble reads the whole thread, O(n^2) thinking durations, JSON parsed and fileExists per render. (CHAT-7)
- [x] **P1** Switching engine silently swaps the visible conversation, even mid-run. Disable while running, add a note. BotPage.swift:337. (CHAT-10)
- [x] **P1** "This folder isn't a git repository" failure has no action. Add Choose folder. ThreadView.swift:633. (CHAT-9)
- [x] **P1** Markdown: `##` headings and `1.` lists render literally; nested bullets lose indent; duplicate block ids. MarkdownBlock.swift. (CHAT-15, CHAT-16)
- [x] **P1** Queued note copy has an em dash and sits centred; design puts it under your bubble. AppModel.swift:809. (CHAT-12)
- [x] **P1** Empty conversation says "Asks before it acts" even for Never asks. BotPage.swift:1053. (CHAT-13)
- [x] **P1** Activity and Files tabs are blank when empty. BotPage.swift:154,274,868. (CHAT-14)
- [x] **P2** Question card disabled while running, but answers queue fine; board shows it live. Cards.swift:344. (CHAT-17)
- [x] **P2** Approval card repeats the command as the reason; "Details" link clashes with the topbar Details; several pending cards share Shift Cmd A (also in groups). Cards.swift, GroupViews.swift:390. (CHAT-25, NAV-8)
- [x] **P2** Retry offered where it can't help (No bot named X, rate limited); queued batch retried as only its last message. (CHAT-26)
- [x] **P2** Limits: three different thresholds, names and colours (pink for low usage); context window size guessed as 200k, even for Codex. (CHAT-18, CHAT-19)
- [x] **P2** Reply/Copy are hover-only and unreachable by keyboard or VoiceOver; icon buttons lack labels; several hit areas under 24pt. (CHAT-27, CHAT-31)
- [x] **P2** VoiceOver reads "idle" before every message. (CHAT-28)
- [x] **P2** Sent text shrinks: messages are 14.6pt, composer 15.7pt; design is 16 for both. (CHAT-29)
- [x] **P2** Composer: send lights up for a draft of only newlines; no focus ring; Esc doesn't cancel reply-to. (CHAT-30)
- [x] **P2** Details panel: fixed 340 (board flexes to about 440), name 16 (board 18), no "No job yet" badge, goals and runs as icons/meta instead of badges, long values clipped. (CHAT-21, CHAT-24, CHAT-33)

## Batch 5: first run and making bots

- [x] **P1** Starter bots (Scout, Builder, Inbox) are seeded before onboarding, contradicting "your first bot", hiding the empty roster, and leaving the person with four bots; Inbox runs on Codex even if Codex isn't signed in. Decide: no starters when onboarding runs, or keep them and change the copy. AppModel.swift:689-727. (ONB-2)
- [x] **P1** After onboarding, the bot doesn't ask what it's for, though the copy promises it. Start the same greeting run `quickCreateBot` uses. (ONB-6); same for empty-roster starter jobs (ONB-29)
- [x] **P1** "New bot" from the palette, menu bar and creator always picks Claude Code, even when only Codex is signed in. One default: first ready engine. (ONB-7)
- [x] **P1** CLI not installed shows raw stderr and "needs a sign-in". Tell not-installed apart and show the install command. Onboarding.swift:1134. (ONB-8)
- [x] **P1** "Your first bot" step overflows the 620pt sheet; no scroll. (ONB-9)
- [x] **P1** Onboarding is scaled down about 25% from the board (mascots, headings 28 vs 44, bubbles, engine cards); W2 Bupsy should be working. (ONB-10)
- [x] **P1** Trust has two vocabularies and two defaults (creator `.ask`, onboarding `.allowlist` "Recommended"). One set of names, default "Asks unless allowed". (ONB-11, CHAT-22)
- [x] **P1** "New bot" means quick-create in some places and the full form in others. Quick-create is "New bot"; the form is "Set up a bot yourself" everywhere. (ONB-12)
- [x] **P1** Section "+" opens the creator showing "Unassigned", then silently moves the bot after. Seed the section in the form. NavRail.swift:411, TeamView.swift:108. (ONB-5)
- [x] **P2** "Asks before leaving the Mac" title contradicts its (correct) detail. Retitle. (ONB-13)
- [x] **P2** Field labels in two sizes in the same form. (ONB-14)
- [x] **P2** Creator header is a pink plus, board shows a bot glyph in the bot's colour; preview 120 vs 132. (ONB-15)
- [x] **P2** Random colour never picks Coral; initial colour out of range. BotCreator.swift:309. (ONB-16)
- [x] **P2** Face picker sizes (faces 40 vs 44, swatches 26 vs 28) and "Surprise me" on its own line without hover. (ONB-17)
- [x] **P2** Empty sidebar shows a second mascot; board shows a caption and "+ New section". (ONB-18)
- [x] **P2** Name fields not focused on appear; Return hint shown while Continue is disabled. (ONB-22)
- [x] **P2** Onboarding a11y: stage read out as seven "asleep"s, engine rows lack selected trait, confetti ignores Reduce Motion. (ONB-20)
- [x] **P2** Onboarding column uses popover colour (darker than content in dark mode); radius 9 tile. (ONB-21)
- [x] **P2** Sign-in status line duplicated in two places and lacks the CLI path. (ONB-24)
- [x] **P2** "Rename bot…" opens the full editor; RenameBotSheet and NewBotSheet are dead code with off-token colours. (ONB-23, NAV-37)

## Batch 6: routines, goals, folder watches and setup pages

- [x] **P1** Standing goal tab is off-board: retitles to "New standing goal", single-line goal, no Bot picker, required "how will it know" vs optional "Stop when", extra Runs picker. ObjectivesView.swift:171. (SET-4)
- [x] **P1** Folder watch tab is off-board: no Bot picker, no File types, extra Name, wrong labels, "Create" vs "Start watching"; typing lost when switching tabs. BotPage.swift:1291. (SET-5)
- [x] **P1** When presets lack 2am and Custom time; non-preset crons show raw "0 2 * * *". (SET-6)
- [x] **P1** Runs picker hides "On a machine" when there's no machine, and can render with no selection when editing; "While bupsy's open" vs "While open". (SET-7)
- [x] **P1** Routine page keeps the details panel open beside it and overflows at small widths. (SET-8)
- [x] **P1** "Background schedule couldn't be set up" never clears after a later success. AppModel.swift:529. (SET-9)
- [x] **P1** Routine runs while the bot is busy are merged, lose their finish notification, and drop out of the routine's history. Tag runs with the routine id (`triggerID`) and attribute by id. (SET-10)
- [x] **P1** Folder watch: missing folder fails silently; changes during a run are dropped, not deferred. AppModel.swift:440. (SET-11)
- [x] **P1** Folder watches can't be edited or opened; delete hidden in a context menu. (SET-12)
- [x] **P1** Servers can't be edited; a toggle the board doesn't show. (SET-13)
- [x] **P1** Add server: duplicate name silently does nothing but closes; args split on spaces break quoting; no placeholders. (SET-14)
- [x] **P1** Machines: any string saves as "Connected"; old errors never clear; start/stop has no pending state; failed rows offer Play. (SET-19, SET-20)
- [x] **P1** Toggles have no accessible names ("switch"). (SET-21)
- [x] **P2** Routine page layout values (820 vs 896, spacing, padding, 1:1.5 split); topbar adds Back and trash; failure callout only under the newest run; no live running row; "5 of 3 scheduled". (SET-22 to SET-25)
- [x] **P2** Routine and watch copy: em dash in the late-run note, lowercase "bupsy". (SET-26)
- [x] **P2** New routine sheet 540 wide (board 600), "Create routine" vs "Save routine"; whitespace trimming lets empty watches through. (SET-27, SET-28)
- [x] **P2** Goal "Check now" gives no feedback; long goals cut off. (SET-29)
- [x] **P2** Apps: primary action not in the topbar (Page can't take actions); footer copy and tool counts differ. (SET-30)
- [x] **P2** Machines: masked key, idle cost, remove key, Return to save. (SET-31)
- [x] **P2** Permissions: rows keyed by offset; "Github"; Edit and Write as two rows. (SET-32)
- [x] **P2** Usage queries the database in `body`; totals include deleted bots; breadcrumb lacks the period. (SET-33)

## Batch 7: design-system consistency

- [ ] **P1** Text on pink is black in some places and white in others; design is #fafafa light, #171717 dark. Make `onPrimary` per scheme. (SYS-2)
- [ ] **P1** Radius tokens are off: controls 8 (design 10), cards 12 (design 14). (SYS-3)
- [ ] **P1** `BupsyFieldStyle` reads the palette from inside a TextFieldStyle and may render dark fields in light mode. Verify on device; make it a ViewModifier. (SYS-9)
- [ ] **P1** App-wide pink tint makes every switch pink when on; design says switches are ink. One switch style and size. (SYS-10)
- [ ] **P1** Four different segmented controls; extract one. (SYS-11)
- [ ] **P1** "bupsy" lowercase in user-visible strings across the app and BupsyKit. (SYS-12, CHAT-22, NAV-40)
- [ ] **P1** Em dashes in user-visible copy (queued, routing, rename notes, late routines, copy-conversation header, model menu). (SYS-13, CHAT-12)
- [ ] **P2** Seven badge/pill implementations; keep one `Badge` per the design. (SYS-14)
- [ ] **P2** Five button styles with different heights and states; one `BupsyButtonStyle` (44 and 36). (SYS-15, NAV-19)
- [ ] **P2** Content max width 820 vs 896 in different places. (SYS-16)
- [ ] **P2** About 250 literal spacings and paddings, control heights from 26 to 56. Sweep to tokens. (SYS-17)
- [ ] **P2** Reduce Motion: composer beam keeps pulsing, confetti animates, thinking timer freezes; still faces always use light ink. (SYS-18, CHAT-20)
- [ ] **P2** Section empty states show an awake bot or nothing; use the napping compact EmptyState. (SYS-20)
- [ ] **P2** Sections use three icons, and `folder` also means the working folder; "Pin to top" never says Unpin; mixed "…" and "..."; "Theme" vs "Appearance". (SYS-21, NAV-12, NAV-40)
- [ ] **P2** Icon-only buttons without accessibility labels; caret and "+" hit targets under 24pt. (SYS-22, NAV-27, ONB-19)
- [ ] **P2** Sidebar status is colour-only for VoiceOver; rows read "idle, Scout, Dev". (SYS-23)
- [ ] **P2** Hard-coded `.red` and `.orange`. (SYS-24)
- [ ] **P2** RootView reads the palette before setting it, so the app tint is dark pink in light mode. (SYS-25)
- [ ] **P2** Topbar crumbs all truncate together. (SYS-27)
- [ ] **P2** Sidebar rows: label colour and weight, row 36 vs 38, header buttons, account row shows "You" not your name, no hover; extra title-bar padding; panel radius. (NAV-26, NAV-29, NAV-39)
- [ ] **P2** You menu and bot context menu differ from the board (17-item bot menu, no Pause, Shuffle face vs Change face); Team menu differs again; share one builder. (NAV-30, NAV-31, NAV-32)
- [ ] **P2** Groups: no Change lead, no rename or archive on the page, copy differs from the board, folded Groups never shows pink. (NAV-20, NAV-21, NAV-28)
- [ ] **P2** Waiting on you: copy, face size, answered cards vanish, hand-sized header. (NAV-22 to NAV-24)
- [ ] **P2** Team: drag uses raw strings (pastes ids into text fields); empty named sections can't exist; cards not keyboard reachable. (NAV-33 to NAV-35)
- [ ] **P2** Rename section: "1 bots", count misses pinned and hidden bots, silent merge on an existing name. (NAV-36)

## Batch 8: assets, docs and cleanup

- [ ] **P2** App icon has no dark or tinted appearance variants; About shows a live mark instead of the icon and "Releases" instead of "Check for updates". (SYS-28)
- [ ] **P2** README hero screenshot and docs/logo.png show the retired look. (SYS-28)
- [ ] **P2** docs/06-design.md describes the old icon, dead thinking components and misses the shared parts files. (SYS-29)
- [ ] **P2** Dead code: inline sidebar search, RenameBotSheet, NewBotSheet, TypingIndicator, DotWave, ShimmerText, ThinkingOrbs, LimitsGauge paths, MachineButton, ObjectivesSheet, RoutinesSheet. (CHAT-34, NAV-37, SYS-29, SET-3)
- [ ] **P2** Empty `Label(systemImage: "")` in menus logs warnings and misaligns. (ONB-25, CHAT-23)

## Not code: decisions for you

1. Starter bots or onboarding's first bot (Batch 5, first item).
2. Unread dot: pink like the board, or keep a second colour so pink only means "needs you".
3. Groups menu: Archive (board) or Delete with a confirm.
4. "Pause all bots" (board) needs a real pause; today it stops runs.
5. Empty named sections: persist them (board shows an empty Work column) or drop that state from the design.
