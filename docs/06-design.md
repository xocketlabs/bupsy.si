# Design

Where bupsy's look is defined, and the rules it follows. The code is the source of truth; this is
the map to it.

## Where it lives

| What | File |
|---|---|
| Colours, light and dark | `Apps/BupsyMac/Sources/Palette.swift` |
| Spacing, radius, sizes, type, shared components (SheetFrame, buttons, fields, SettingsGroup/Row, CardRow) | `Apps/BupsyMac/Sources/Theme.swift` |
| Bupsy, the mascot every bot wears: 8 shapes, 8 colours, 6 moods and their motion | `Apps/BupsyMac/Sources/BotFace.swift` |
| Logo mark and app icon (the icon PNGs are rendered from the design system's `bupsy-app-icon.svg`) | `Apps/BupsyMac/Sources/BupsyMark.swift` |
| Bot creator (face ring, colours, identity and preference cards) | `Apps/BupsyMac/Sources/BotCreator.swift` |
| Agent thinking indicator (dot wave, shimmer label, timer) | `Apps/BupsyMac/Sources/AgentThinking.swift` |
| Limits card (context window, plan limits) | `Apps/BupsyMac/Sources/AgentLimits.swift` |
| Spotlight-style search / new panel | `Apps/BupsyMac/Sources/StartChat.swift` |
| Landing page | `site/index.html` (its own CSS tokens at the top) |

## Colour

One saturated colour, pink (`primary`), for the thing that needs you: your messages, the send
button, approvals, selection. Violet (`info`) is the second accent. Everything else is greys.

Dark mode layers *inverted*: the sidebar is the darkest surface, content sits above it, cards
above that. Depth comes from those steps, so borders and shadows are rare. Light mode follows
the same steps in reverse. Appearance is Auto / Light / Dark in the "You" menu.

Status colours come from `success`, `warning`, `infoText` and `destructiveText`; the last two are
the text-safe versions of `info` and `destructive`.

Every bot has its own colour from `BotShape.palette` (the design system's `--bot-1` to `--bot-8`); it is used for the bot's name in groups,
its @mention chips and its thinking dots, so a bot reads as the same character everywhere.

## Type and spacing

System font, scaled by `Theme.textScale` (1.12) through `Theme.scaled(_:)`. Use the
`Theme.Typography` styles (title, heading, body, label, caption, badge) rather than raw sizes.
Spacing comes from `Theme.Space` (tight, snug, step, gutter, section); radii from `Theme.Radius`.

## Components

- **The mascot** is ported from the design system's `Mascot` and drawn from the same 120-unit
  geometry. The antenna light is the status (violet idle, green working or done, a white flash
  when it needs you, grey asleep, red on error); the face carries the rest. Reduce Motion freezes
  every face. Empty places use `EmptyState`, a napping bot with one line of why.
- **Popups** use `SheetFrame`, the design system's Sheet: a panel in a grey lip, keyboard hints and
  the actions on the lip. The header tile is washed in a `SheetTone`; pass `bot:` and that bot
  peeks over the panel's edge instead. Then Cancel and
  a pink primary button. The bot creator is the one exception — it is its own full sheet.
- **Settings** are `SettingsGroup` cards of `SettingRow`s: label on the left, value and menu on
  the right.
- **Search & new** is one panel (`StartChatPalette`) opened by + and ⌘F.
- **Working state**: `AgentThinking` under the thread, and a breathing pink outline on the
  composer (`BorderBeam`).

## Characters

Bots are plush faces, never avatars of people. The app icon is three of them huddled under
bupsy's bubbles; the small mark is the lead bot with its bubble, because three faces do not read
at sidebar size. Both are drawn in code, so the icon, the mark and the bots are the same drawing.

## Screenshots

`--tour` mode (debug builds) renders every screen in light and dark from demo data — see
`TourMode.swift`. Never screenshot a real database.
