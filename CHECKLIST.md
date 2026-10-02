# Where bupsy is

Plain-language status. Updated with every change — if a box is ticked, it works and has tests.

**Today:** the app runs, you can chat with bots, it remembers everything, and bots ask before
they act. Routines and cloud machines are built underneath but have no buttons yet.

---

## Done

### The engine
- [x] Runs **Claude Code** on your Mac, under your own sign-in
- [x] Runs **Codex** too — proves the design isn't locked to one vendor
- [x] Replies stream in live, word by word
- [x] Shows what a bot is doing (commands it ran, files it touched)
- [x] Knows the difference between *signed in* and *actually able to run*
- [x] Shows how much of your subscription you've used

### The app
- [x] Native Mac app, opens in under a second
- [x] Sidebar of bots you click between
- [x] Chat with any bot
- [x] Add a new bot
- [x] Remembers everything when you quit and reopen
- [x] Transcripts **can't be edited**, even by us

### Safety
- [x] Bots ask before running commands — you tap Allow or Deny
- [x] If nobody answers, it says **no** (never yes)
- [x] Four trust levels, from "ask me everything" to "just do it"
- [x] Every decision is written down permanently
- [x] A stop button that halts everything
- [x] Bots can keep your Mac awake while working, so long jobs don't die

### Per-bot settings — right-click any bot
- [x] **Swap engine** — Claude ↔ Codex, keeping each engine's own thread
- [x] **Pick a model** — Opus, Sonnet, Haiku, Fable, or the Codex ones
- [x] Trust level
- [x] Which machine it uses
- [x] Whether it keeps your Mac awake

### Standing goals
- [x] A goal plus how to tell it's met — the bot judges each check
- [x] Asks you rather than guessing
- [x] Remembers what it learns, in plain text you can edit
- [x] Everything waiting on you in one tray

### Apps
- [x] Your MCP servers, run on your machine — not integrations we wrote
- [x] Tokens go in your own shell, never through us
- [x] Real connection status, not a guess
- [x] Allow a whole app per bot, so new tools in it don't need re-approving

### Machines
- [x] Your key, your account, your bill — bupsy has no cloud of its own
- [x] Key lives in the Mac's Keychain, never leaves this Mac
- [x] Cost shown before you create anything
- [x] Deleting a machine doesn't delete its bots

### Routines
- [x] Create one: pick a bot, write the job, choose when
- [x] Runs with the app closed — launchd starts it
- [x] A job missed while your Mac slept runs once when it wakes
- [x] Away a fortnight? One catch-up run, not fourteen
- [x] Every option says honestly what it will and won't do

### Underneath, no buttons yet
- [x] Cloud machines — create, start, stop, run things on them
- [x] Installing a schedule inside a cloud machine

---

## Next, in order

### 1. Make a routine ✅ **done**
- [x] Button to create one: pick a bot, write the job, choose when
- [x] See your routines and turn them off
- [x] Choose where it runs, and see honestly what that means
- [x] App starts itself to run them, even when closed

### 2. Add a cloud machine ← **mostly done**
- [x] Paste your own boat key, kept in the Mac's Keychain
- [x] Create a machine and name it
- [x] Start and stop it
- [x] Assign bots to it — right-click a bot
- [x] See what it's costing you, before you create it
- [ ] Sign a bot's engine in *on that machine* — needs a terminal window
- [ ] Watch its screen
- [ ] **Needs your boat key to prove it works against the real service**

### 3. Make it look good ✅ **done**
- [x] Animated bot faces — they blink, and show at a glance who's busy or stuck
- [x] Nicer waiting animation
- [x] Glowing border on the box while a bot replies
- [x] First-run walkthrough
- [x] Settings live in a right-click menu on each bot

### 4. Connect your apps ✅ **done**
- [x] Add any MCP server — GitHub, Slack, Notion, Files suggested, anything else by hand
- [x] Choose which bot can use which app, without being asked each time
- [x] See which apps actually connected, reported by the engine itself
- [x] bupsy never stores an app's password or token

### 5. Standing goals ✅ **done**
- [x] "Keep my inbox at zero" — ongoing, not a one-off job
- [x] Checks on a schedule and does nothing when all is well
- [x] Bots learn as they go, and you can read and correct what they learned
- [x] One place showing everything waiting on you, with a count in the toolbar
- [x] Never claims a goal is handled when it isn't sure

### 6. Ship it ← **written, waiting on your Apple account**
- [x] Build, sign, notarize and package script — runs locally and in CI
- [x] One-command release: push a tag, get a DMG on GitHub
- [x] Step-by-step release guide
- [x] Licence set to Xocket Labs Inc., a Delaware corporation
- [ ] **Needs your Apple Developer account ($99/yr)** — docs/05-release.md
- [ ] Auto-updates — deliberately off until there's somewhere to host the feed
- [ ] Website

---

## Waiting on you

| What | Why it matters |
|---|---|
| **Click Send once** | I can't test the app's own buttons — needs a permission that's yours to give |
| **A boat.dev key** | Turns the cloud machine code from written to working |
| **A lawyer on the Use Grant** | Not blocking, but worth an hour before the first public build |
| **Apple Developer account** ($99/yr) | Blocks a downloadable app, and the wake helper |
| **Which ChatGPT plan has Codex?** | Yours signs in but can't run a model |

---

## Decided against, on purpose

- **Phone app** — not in version 1. Keeps the Mac app with zero network surface.
- **Voice** — later. Neither competitor leads with it.
- **Windows / Linux** — Mac first, then reassess.
- **Waking your Mac for free** — impossible without root. Needs the opt-in helper, or a cloud machine.

See [docs/03-decisions.md](docs/03-decisions.md) for why, and [PLAN.md](PLAN.md) for the long version.
