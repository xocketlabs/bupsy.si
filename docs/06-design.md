# Design

Where Bupsy's look is defined, and the rules it follows. The code is the source of truth for the
app; this page is the map to it.

The design system itself lives in two artifacts:

- Design system (tokens, components, mascot, icons): https://claude.ai/artifact/QfEsdbRK36qfCNHYegZx8P
- Screens canvas (every screen, light and dark): https://claude.ai/artifact/4UN61oRG9HGfkpKiN65SGo

When the app and the artifact disagree, fix one of them so they match again.

## Where it lives

| What | File |
|---|---|
| Colours, light and dark | `Apps/BupsyMac/Sources/Palette.swift` |
| Tokens (space, radius, size, type) and shared components | `Apps/BupsyMac/Sources/Theme.swift` |
| The mascot: 8 shapes, 8 colours, 6 moods and their motion; the composer's `BorderBeam` | `Apps/BupsyMac/Sources/BotFace.swift` |
| Logo mark and app icon | `Apps/BupsyMac/Sources/BupsyMark.swift` |
| Menu bar icon and menu | `Apps/BupsyMac/Sources/MenuBar.swift` |
| Setup pages (Apps, Usage, Permissions, Machines) | `Apps/BupsyMac/Sources/SetupParts.swift` |
| Thread layout, tool calls, thread badges and buttons, nested cards | `Apps/BupsyMac/Sources/ThreadParts.swift` |
| The stage the mascot stands on (onboarding, bot creator preview) | `Apps/BupsyMac/Sources/MascotStage.swift` |
| The thinking line under a working thread | `Apps/BupsyMac/Sources/AgentThinking.swift` |
| Limits card and the limit colour scale (`LimitScale`) | `Apps/BupsyMac/Sources/AgentLimits.swift` |
| Bot creator | `Apps/BupsyMac/Sources/BotCreator.swift` |
| Search and new panel (`StartChatPalette`) | `Apps/BupsyMac/Sources/StartChat.swift` |
| Landing page | `site/index.html` (its own CSS tokens at the top) |

## Colour

One saturated colour, pink (`primary`), for the thing that needs you: your messages, the send
button, approvals, selection. Text on pink uses `onPrimary` (near white in light mode, near
black in dark mode, where the pink is lighter). Violet (`info`) is the second accent. Everything
else is greys.

Dark mode layers inverted: the sidebar is the darkest surface (`sidebar`), content sits above it
(`background`), cards above that (`card`, then `cardHover`). Depth comes from those steps, so
borders and shadows are rare. Light mode keeps the same steps from white. Appearance is Auto,
Light or Dark, in the You menu and in Settings. Views read colours from `@Environment(\.palette)`,
resolved once at the root with `withPalette(_:)`.

Status colours are `success`, `warning`, `infoText` and `destructiveText`. The last two are the
text-safe versions of `info` and `destructive`; use them for any words. `switchOff` is a switch's
off track.

Every bot has its own colour from `BotShape.palette` (the design system's `--bot-1` to `--bot-8`:
Pink, Violet, Blue, Teal, Green, Lime, Amber, Coral), one lightness and chroma round the hue
wheel so no bot outshouts another. It is used for the bot's face, its name in groups and its
@mention chips, so a bot reads as the same character everywhere.

## Tokens

- **Type.** System font, scaled by `Theme.textScale` (1.12) through `Theme.scaled(_:)`. Use
  `Theme.Typography`: `title` 22 semibold, `heading` 15 medium, `lead` 14, `body` 13, `label`
  12, `caption` 11, `badge` 10 medium (all before scaling).
- **Space.** `Theme.Space`: `hairline` 2, `xs` 4, `tight` 6, `snug` 8, `compact` 10, `step` 12,
  `gutter` 16, `section` 24, `pageSide` 32, `page` 40.
- **Radius.** `Theme.Radius`: `sm` 6, `md` 8, `lg` 10, `xl` 14. Buttons, chips, badges and fields
  are `lg`; cards, panels and rows are `xl`; `md` is for things nested inside an `lg`.
- **Size.** `Theme.Size`: controls are `controlLg` 44 (page and dialog actions, fields),
  `controlMd` 36 (inside cards, segmented controls) and `controlSm` 28 (dense rows, icon
  buttons). A row is 36, a leading tile 44. Content stops at `contentMaxWidth` 896; bubbles at
  `bubbleMaxWidth` 560.

## Components

One component per job. Do not hand-roll a pill, button, switch or field; if the shared one does
not fit, change it.

- **Badge** with a `BadgeTone`: `neutral`, `info`, `primary` ("Needs you": pink wash and dot, ink
  text), `success`, `warning`, `destructive`, or `custom(Color)`. Optional dot for live states.
  `ThreadStatusBadge` and `SetupBadge` are thin wrappers.
- **Buttons.** `BupsyButtonStyle(kind:size:)`. Kinds: `primary` (pink, at most one per view),
  `secondary`, `outline`, `ghost`, `destructive` (a red tint, never a solid slab),
  `ghostDestructive`. Sizes: `lg` 44, `md` 36, `sm` 28. `PrimaryButton` is primary at `lg`;
  `QuietButton` is secondary at `lg`, or `md` when `compact`. `ThreadButtonStyle` is an older
  wrapper; new code uses `BupsyButtonStyle`.
- **Fields.** `.bupsyField()` on a text field, inside `Field` for a label and a help line.
- **Switches.** `.bupsySwitch()`: a 36 by 20 track, ink when on, `switchOff` when off. Not `.tint`.
- **Segmented.** `Segmented` for two to five short options, 36 tall; `full` stretches it.
- **Chips and rows.** `MenuChip` (a fact that is also its menu), `MetaChip`, `IconTile`,
  `CardRow`, `MetaDot`, `SectionHeader`, `FactRow`.
- **Settings.** `SettingsGroup` cards of `SettingRow`s: label on the left, value and menu on the
  right.
- **LimitBar.** How much of a subscription window is gone, with its reset time. Coloured only
  once it is worth noticing, on the one `LimitScale`.
- **Popups.** `SheetFrame`, the design system's Sheet: a panel in a grey lip, keyboard hints
  (`Keycap`) on the left of the lip and Cancel plus one primary action on the right. The header
  tile is washed in a `SheetTone`; pass `bot:` and that bot peeks over the panel's edge instead.
  `SheetCloseButton` is the corner cross; Esc presses it. The bot creator is the one exception:
  it is its own full sheet.
- **Empty places.** `EmptyState`: a napping grey bot, one line of why, at most one action. Pass
  `.done` and a colour when empty is good news. Inside a page with other content, use
  `SetupEmptyNote`.

### Shared parts files

- **SetupParts.swift** gives the setup pages one shape: `SetupPageScroll`, `SetupPageHeader`,
  `SetupSectionHeader`, `SetupListRow`, `SetupIconButton` (28pt, red for removals, always with
  help and a VoiceOver label), `SetupPanel`, `SetupEmptyNote`, `SetupSectionRule`,
  `SetupFootnote`.
- **ThreadParts.swift** holds `ThreadLayout` (a reply leads with a 28pt face and a 12pt gap, so
  everything in that reply sits 40pt in), `ThreadRowContext`, `ToolCallInfo`,
  `ThreadStatusBadge`, `ThreadButtonStyle`, `ThreadNestedCard` (a card with a tinted lip, pink for
  an approval, grey for a question) and `ThreadComposerPeek` (a bot hiding behind the composer).
- **MascotStage.swift** is the tinted, dotted ground a bot performs on: `MascotStageBackground`,
  `MascotStageDots`, `MascotStageGlow`, `MascotStageBubble`, `MascotStageTag`,
  `MascotStageSpot`, `MascotStageDash`, `MascotStagePeek` and `MascotStageConfetti` (drifts in
  once, then holds still).

## The mascot

Bots are plush faces, never avatars of people. `BotFace` is ported from the design system's
`Mascot` and drawn from the same 120-unit geometry in one `Canvas`.

- **Shapes.** Eight: bup, blob, pill, cat, bunny, bear, ghost and horns, shown in the picker as
  "Imp". Every shape keeps the antenna. A bot that never picked wears Bup in a colour derived
  from its name.
- **Moods.** Six: idle, working, waiting for you, done, sleeping, failed. The antenna light is the
  status (violet idle, green working or done, a white flash when it needs you, grey asleep, red
  on error); the eyes, brows, mouth and a small motion carry the rest.
- **Still and alive.** Alive faces run on a `TimelineView`. Pass `still: true` (or use
  `StillBotFace`) where a face is on screen but not the point, such as an idle row in a long list,
  and for image renders.
- **Reduce Motion** freezes every face on one calm frame.

## Icons

- **App icon.** Bupsy rising out of the bottom edge of a charcoal macOS tile, its antenna light
  glowing violet near the top, the face large enough to read at 16pt. `BupsyAppIcon` renders it
  on Apple's 1024 grid, matching `bupsy-app-icon.svg` in the design system.
- **Logo mark.** `BupsyMark` (and `BupsyIconMark` in the sidebar header) is the pink Bup with its
  violet antenna light, drawn with `BotFace`, alive in the sidebar and still elsewhere.
- **Menu bar.** `MenuBarGlyph` draws `bupsy-menubar-template.svg` at 18pt as a template image the
  system tints. When something needs you it is drawn in the menu bar's label colour with a pink
  dot. Its help and VoiceOver label are the status line ("2 working, 1 needs you").

## Working state

- `AgentThinking` sits under the thread while a bot works: the bot's own face in its working mood
  at 22pt, its current step in words ("Searching the web", "Editing hello.txt") breathing on a
  2.2s cycle, and a timer counting up. It hides the moment an approval card appears, so
  "working" and "needs you" never show at once. Under Reduce Motion the words hold still and the
  timer ticks in whole seconds.
- The composer gets a breathing pink outline (`BorderBeam`), a plain border under Reduce Motion.

## Rules

- **Tokens, not literals.** Colours from the palette, sizes from `Theme`. A hand-picked number in a
  view is how the interface drifts.
- **Copy.** Sentence case everywhere. "Bupsy" is capitalised. No em dashes. Use "…", not "...".
- **Motion.** Every animation checks `accessibilityReduceMotion` and has a still form.
- **Icon-only buttons** carry `.help` and an `accessibilityLabel` with the same words.
- **Targets** are at least 24pt; the smallest control size is 28.

## Screenshots

`--tour` mode (debug builds) renders every screen in light and dark from demo data; see
`TourMode.swift`. Never screenshot a real database.
