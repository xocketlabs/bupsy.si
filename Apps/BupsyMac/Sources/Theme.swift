import BupsyKit
import SwiftUI

/// The measurements the whole app is built on, ported from the Agndex dashboard's rhythm.
///
/// A design reads as finished when its numbers repeat. These are the only ones views should
/// reach for — anything hand-picked in a view is how an interface drifts back to looking
/// approximate.
enum Theme {
    /// A 4pt grid, used at the steps Agndex actually uses: 8 / 12 / 16 / 24 / 40.
    enum Space {
        static let tight: CGFloat = 6
        static let snug: CGFloat = 8
        static let step: CGFloat = 12
        static let gutter: CGFloat = 16
        static let section: CGFloat = 24
        static let page: CGFloat = 40
        /// The in-between steps the design also uses: 2 (a segmented track's inset), 4, 10 (a
        /// badge's or a ghost button's side padding) and 32 (a page's side margin).
        static let hairline: CGFloat = 2
        static let xs: CGFloat = 4
        static let compact: CGFloat = 10
        static let pageSide: CGFloat = 32
    }

    /// The design's radius scale. Buttons, chips, badges and fields are `lg`; panels, cards and
    /// list rows are `xl`; `md` is for things nested inside an `lg` (a segmented option).
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 14
        /// rounded-lg: chips, buttons, icon tiles.
        static let control: CGFloat = lg
        /// The base radius.
        static let base: CGFloat = lg
        /// rounded-xl: cards and rows.
        static let card: CGFloat = xl
        static let bubble: CGFloat = xl
    }

    enum Size {
        /// h-11. Every control lands on this height, which is what makes a row of mixed
        /// buttons, chips and fields look deliberate rather than assembled.
        static let control: CGFloat = 44
        /// The large control height under its design name (page actions, fields).
        static let controlLg: CGFloat = 44
        /// The in-card control height: buttons inside cards, segmented controls, menus in rows.
        static let controlMd: CGFloat = 36
        /// The small control height: compact chips and icon buttons at the end of a row.
        static let controlSm: CGFloat = 28
        /// One list or settings row.
        static let row: CGFloat = 36
        /// size-11 — the square tile that leads a card row.
        static let tile: CGFloat = 44
        static let rosterAvatar: CGFloat = Theme.scaled(36)
        static let bubbleAvatar: CGFloat = Theme.scaled(24)
        static let profileAvatar: CGFloat = 72
        /// max-w-4xl. Content stops here however wide the window is; a line of text that spans a
        /// display is hard to read and stops looking composed.
        static let contentMaxWidth: CGFloat = 896
        static let bubbleMaxWidth: CGFloat = 560
    }

    /// Agndex leans on small, tight-tracked type rather than many sizes.
    /// One knob for the size of every piece of text in the app.
    ///
    /// The type had been set at macOS's own defaults — 13pt body, 11pt captions — which read as
    /// small in an app you sit in for hours rather than glance at, and the owner said so. Every
    /// token below and every remaining hard-coded size goes through `scaled`, so the whole app
    /// moves together and tuning it again is this one number rather than thirty edits that drift.
    static let textScale: CGFloat = 1.12

    static func scaled(_ size: CGFloat) -> CGFloat { size * textScale }

    enum Typography {
        static let title = Font.system(size: Theme.scaled(22), weight: .semibold)
        static let heading = Font.system(size: Theme.scaled(15), weight: .medium)
        /// The sentence under a page title.
        static let lead = Font.system(size: Theme.scaled(14))
        static let body = Font.system(size: Theme.scaled(13))
        static let label = Font.system(size: Theme.scaled(12))
        static let caption = Font.system(size: Theme.scaled(11))
        static let badge = Font.system(size: Theme.scaled(10), weight: .medium)
    }

    static func stamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: now), date > week {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func daySeparator(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - The pieces Agndex repeats

/// A chip that is also the control for the fact it states.
///
/// In a dashboard, a row of read-only labels sitting next to a hidden menu is the worst of both:
/// the fact is visible and changing it is not. These carry a menu, so the thing you can see is
/// the thing you can change.
struct MenuChip<Content: View>: View {
    @Environment(\.palette) private var palette
    /// nil inside a settings row, where the row already carries the icon.
    let icon: String?
    let text: String
    var emphasised = false
    /// Shorter and quieter, for sitting at the end of a row rather than standing alone on a page.
    var compact = false
    var tone: Color?
    @ViewBuilder var menu: Content
    @State private var hovering = false

    var body: some View {
        Menu {
            menu
        } label: {
            HStack(spacing: compact ? Theme.Space.tight : Theme.Space.snug) {
                if let icon {
                    Image(systemName: icon).font(.system(size: Theme.scaled(12)))
                }
                // Coloured here rather than left to the enclosing `foregroundStyle`. A
                // `.borderlessButton` menu adopts the app tint for its label, so once a tint was
                // set at the root every settings value turned accent-pink — six rows all
                // shouting, and nothing left to mark the one that matters.
                Text(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(tone ?? (emphasised ? palette.foreground : palette.mutedForeground))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !compact {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Theme.scaled(8), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground.opacity(hovering ? 1 : 0.45))
                }
            }
            .foregroundStyle(tone ?? (emphasised ? palette.foreground : palette.mutedForeground))
            .padding(.horizontal, compact ? Theme.Space.snug : Theme.Space.step)
            .frame(height: compact ? 28 : Theme.Size.control)
            .background(hovering ? palette.cardHover : palette.secondary,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(tone?.opacity(0.35) ?? palette.border)
            }
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// A pill of secondary information: an icon and a short label at control height.
struct MetaChip: View {
    @Environment(\.palette) private var palette
    let icon: String
    let text: String
    var emphasised = false
    /// Set only for a chip that should carry weight — an engine that cannot run, a bot with the
    /// brakes off. Left nil, a chip is an ordinary fact and stays grey.
    var tone: Color?

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: icon).font(.system(size: Theme.scaled(12)))
            Text(text).font(Theme.Typography.body)
        }
        .foregroundStyle(tone ?? (emphasised ? palette.foreground : palette.mutedForeground))
        .padding(.horizontal, Theme.Space.step)
        .frame(height: Theme.Size.control)
        .background(palette.secondary, in: .rect(cornerRadius: Theme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(tone?.opacity(0.35) ?? palette.border)
        }
    }
}

/// The tones a `Badge` can take, from the design's `.bp-badge` variants.
enum BadgeTone: Equatable {
    /// Grey: engine names and plain facts.
    case neutral
    /// Violet: counts and neutral information. Text uses `infoText`.
    case info
    /// "Needs you": a pink wash and a pink dot, but ink text, because pink text is too faint.
    case primary
    case success
    case warning
    case destructive
    /// Any other colour, washed at 10% behind text in that colour.
    case custom(Color)

    /// A colour handed in by an older call site, mapped onto the named tone it matches so a
    /// palette token gets the design's treatment (info text, ink on "Needs you").
    static func matching(_ colour: Color?, in palette: Palette.Scheme) -> BadgeTone {
        guard let colour else { return .neutral }
        if colour == palette.primary { return .primary }
        if colour == palette.info || colour == palette.infoText { return .info }
        if colour == palette.success { return .success }
        if colour == palette.warning { return .warning }
        if colour == palette.destructive || colour == palette.destructiveText { return .destructive }
        if colour == palette.mutedForeground { return .neutral }
        return .custom(colour)
    }

    func text(_ palette: Palette.Scheme) -> Color {
        switch self {
        case .neutral: palette.mutedForeground
        case .info: palette.infoText
        case .primary: palette.foreground
        case .success: palette.success
        case .warning: palette.warning
        case .destructive: palette.destructiveText
        case .custom(let colour): colour
        }
    }

    func fill(_ palette: Palette.Scheme) -> Color {
        switch self {
        case .neutral: palette.secondary
        case .info: palette.info.opacity(0.1)
        case .primary: palette.primary.opacity(0.14)
        case .success: palette.success.opacity(0.1)
        case .warning: palette.warning.opacity(0.1)
        case .destructive: palette.destructive.opacity(0.1)
        case .custom(let colour): colour.opacity(0.1)
        }
    }

    func dot(_ palette: Palette.Scheme) -> Color {
        self == .primary ? palette.primary : text(palette)
    }
}

/// The app's one badge, per the design's `.bp-badge`: radius lg, 6 by 10 padding, 12pt regular
/// text in the tone over the tone at 10%, and an optional 6pt dot in front for live states.
///
/// `ThreadStatusBadge` and `SetupBadge` are thin wrappers over this; new code should use it
/// directly.
struct Badge: View {
    @Environment(\.palette) private var palette
    let text: String
    let tone: BadgeTone
    let dot: Bool
    /// Kept only for colour call sites, so a token colour can be matched at draw time.
    private let colour: Color?
    private let usesColour: Bool

    init(text: String, tone: BadgeTone = .info, dot: Bool = false) {
        self.text = text
        self.tone = tone
        self.dot = dot
        self.colour = nil
        self.usesColour = false
    }

    /// The older colour form. Nil is the info tone, as it always was for `Badge`.
    init(text: String, tone colour: Color?, dot: Bool = false) {
        self.text = text
        self.tone = .info
        self.dot = dot
        self.colour = colour
        self.usesColour = colour != nil
    }

    private var resolved: BadgeTone {
        usesColour ? BadgeTone.matching(colour, in: palette) : tone
    }

    var body: some View {
        let tone = resolved
        HStack(spacing: Theme.Space.tight) {
            if dot {
                Circle()
                    .fill(tone.dot(palette))
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(Theme.Typography.label)
        .foregroundStyle(tone.text(palette))
        .padding(.vertical, Theme.Space.tight)
        .padding(.horizontal, Theme.Space.compact)
        .background(tone.fill(palette), in: .rect(cornerRadius: Theme.Radius.lg))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The square that leads a card row. Bordered and set to the sidebar colour so it reads as a
/// recess in a lifted card — the trick that gives these rows their depth without a shadow.
struct IconTile: View {
    @Environment(\.palette) private var palette
    let systemName: String
    var size: CGFloat = Theme.Size.tile

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.38))
            .foregroundStyle(palette.mutedForeground)
            .frame(width: size, height: size)
            .background(palette.sidebar, in: .rect(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(palette.border)
            }
    }
}

/// A lifted row: tile, title, a line of meta, actions. The dashboard's main repeating unit.
struct CardRow<Leading: View, Content: View, Trailing: View>: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false

    @ViewBuilder var leading: Leading
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.step) {
            leading
            content
            Spacer(minLength: Theme.Space.snug)
            trailing
        }
        .padding(Theme.Space.step)
        .background(hovering ? palette.cardHover : palette.card,
                    in: .rect(cornerRadius: Theme.Radius.card))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The dot that separates items on a meta line, rather than a slash or a pipe.
struct MetaDot: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Circle()
            .fill(palette.mutedForeground.opacity(0.55))
            .frame(width: 3, height: 3)
    }
}

/// A heading with its supporting line, the shape every Agndex section starts with.
struct SectionHeader<Trailing: View>: View {
    @Environment(\.palette) private var palette
    let icon: String
    let title: String
    var badge: String?
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.step) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: icon)
                        .font(.system(size: Theme.scaled(13)))
                        .foregroundStyle(palette.mutedForeground)
                    Text(title).font(Theme.Typography.heading).foregroundStyle(palette.foreground)
                    if let badge { Badge(text: badge) }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.leading, 21)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// A settings group: a quiet label, then a card of rows.
///
/// The pattern every macOS settings screen uses, and the one bupsy was not using. A horizontal
/// row of chips reads fine on a wide page and falls apart in a column — it cannot wrap, the
/// labels truncate, and there is nowhere to say what a setting means. Rows in a card stack at any
/// width and leave room on the left for a word.
struct SettingsGroup<Content: View>: View {
    @Environment(\.palette) private var palette
    /// Off in a Settings pane, whose own heading already says what the card is.
    @Environment(\.settingsGroupShowsTitle) private var showsTitle
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if showsTitle {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.horizontal, 2)
            }

            // As wide as the column it is in, so a card whose rows are short (one switch) lines up
            // with the full-width cards and notes around it instead of hugging its words.
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .stroke(palette.border, lineWidth: 1))
        }
    }
}

/// One row inside a `SettingsGroup`: what it is on the left, the control that changes it on the
/// right.
///
/// The menu is a compact control at the end of the row rather than the row itself. SwiftUI's
/// `Menu` sizes to its label on macOS, so a full-width label collapses to its content and centres
/// — which is what the first attempt at this did. Keeping the control discrete also means the
/// name of the setting stays plain text and holds its place when the value is long.
struct SettingRow<Menu: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    var icon: String?
    var tone: Color?
    /// Drawn between rows, never above the first one.
    var showsDivider = true
    @ViewBuilder var menu: Menu

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(palette.border)
                    .frame(height: 1)
                    .padding(.leading, Theme.Space.step)
            }
            HStack(spacing: Theme.Space.snug) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: Theme.scaled(11)))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 14)
                }
                Text(label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.tight)
                MenuChip(icon: nil, text: value, compact: true, tone: tone) { menu }
            }
            .padding(.horizontal, Theme.Space.step)
            .frame(minHeight: 40)
        }
    }
}

/// The frame every dialog in the app wears, matching the design system's Sheet.
///
/// A white panel sitting in a grey lip, the footer living on the lip: keyboard hints on the left
/// (Esc to cancel, Return to confirm), Cancel and exactly one primary action on the right. The
/// header leads with a 44pt tile washed in one tone. When a bot is the one asking, there is no
/// tile: the bot itself peeks over the panel's top edge with its paws on the rim, so you can tell
/// at a glance who wants something.
struct SheetFrame<Content: View, Actions: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// An SF Symbol for the header tile: what kind of thing this dialog makes, at a glance.
    var icon: String?
    var subtitle: String?
    var width: CGFloat = 420
    /// False only where there is no neutral way out: a permission question must be answered, and
    /// closing it without an answer would silently drop what it was asking about.
    var closable = true
    /// The tile's wash. Primary for making things, info for schedules, destructive for removals.
    var tone: SheetTone = .primary
    /// The bot this dialog is about. It peeks over the panel instead of an icon tile.
    var bot: Bot?
    /// The word after "Return to" in the footer hint, e.g. "save" or "create".
    var primaryVerb = "confirm"
    /// Narrow sheets hide the keycaps so they don't wrap beside the buttons.
    var hints = true
    /// A colour for the header tile in place of the tone's, such as the colour a new bot is wearing.
    var tint: Color? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    private var tileColour: Color { tint ?? tone.colour(palette) }

    private let peekHeight: CGFloat = 48
    private let peekSize: CGFloat = 76

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let bot {
                BotFace(bot: bot, mood: .waitingForYou, size: peekSize)
                    .offset(x: Theme.Space.section - 4, y: 0)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 0) {
                if bot != nil { Color.clear.frame(height: peekHeight) }

                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    header
                    VStack(alignment: .leading, spacing: Theme.Space.gutter) { content }
                }
                .padding(Theme.Space.section)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(panelColour, in: .rect(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 2)
                .padding(.top, bot == nil ? 2 : 0)

                footer
            }

            if let bot { paws(for: bot) }
        }
        .frame(width: width)
        .background(lipColour)
        // The app's own accent, so focus rings and default buttons stop arriving in system blue.
        .tint(palette.primary)
    }

    private var panelColour: Color { colorScheme == .dark ? palette.card : palette.background }
    private var lipColour: Color { colorScheme == .dark ? palette.sidebar : palette.card }

    /// Title and a sentence of why, with the tile in front and a close button in the corner.
    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.gutter) {
            if let icon, bot == nil {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(17), weight: .medium))
                    .foregroundStyle(tileColour.opacity(0.95))
                    .frame(width: Theme.Size.tile, height: Theme.Size.tile)
                    .background(tileColour.opacity(colorScheme == .dark ? 0.2 : 0.13),
                                in: .rect(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(tileColour.opacity(0.22))
                    }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: Theme.scaled(18), weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(palette.foreground)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if closable {
                SheetCloseButton { dismiss() }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.snug) {
            if hints {
                HStack(spacing: 4) {
                    Keycap("Esc")
                    Text("to cancel")
                    Keycap("Return").padding(.leading, Theme.Space.snug)
                    Text("to \(primaryVerb)")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(1)
                .fixedSize()
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.leading, Theme.Space.gutter)
        .padding(.trailing, Theme.Space.step)
        .padding(.vertical, Theme.Space.step)
    }

    /// Two paws hooked over the panel's top edge, drawn in front of it.
    private func paws(for bot: Bot) -> some View {
        let tint = BotShape.rgbPalette[(bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue))
                                       % BotShape.rgbPalette.count]
        let fill = LinearGradient(colors: [tint.mixed(with: .hex(0xFFFFFF), 0.62).color, tint.color],
                                  startPoint: .top, endPoint: .bottom)
        let rim = tint.mixed(with: .hex(0x000000), 0.72).color.opacity(0.5)
        let left = Theme.Space.section - 4 + peekSize * 0.11
        let right = Theme.Space.section - 4 + peekSize * 0.66
        func paw(x: CGFloat, angle: Double) -> some View {
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 8, bottomLeading: 5,
                                                      bottomTrailing: 5, topTrailing: 8))
                .fill(fill)
                .shadow(color: rim, radius: 0.5, y: 1)
                .frame(width: 15, height: 10)
                .rotationEffect(.degrees(angle))
                .offset(x: x, y: peekHeight - 5)
        }
        return ZStack(alignment: .topLeading) {
            paw(x: left, angle: -6)
            paw(x: right, angle: 6)
        }
        .accessibilityHidden(true)
    }
}

/// The wash behind a sheet's icon tile.
enum SheetTone {
    case primary, info, success, warning, destructive, neutral

    func colour(_ palette: Palette.Scheme) -> Color {
        switch self {
        case .primary: palette.primary
        case .info: palette.info
        case .success: palette.success
        case .warning: palette.warning
        case .destructive: palette.destructive
        case .neutral: palette.mutedForeground
        }
    }
}

/// The close cross for a sheet: turns a quarter on hover, and Esc presses it.
struct SheetCloseButton: View {
    @Environment(\.palette) private var palette
    let action: () -> Void
    @State private var hovering = false

    init(action: @escaping () -> Void) { self.action = action }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: Theme.scaled(11), weight: .semibold))
                .foregroundStyle(hovering ? palette.foreground : palette.mutedForeground)
                .rotationEffect(.degrees(hovering ? 90 : 0))
                .frame(width: 28, height: 28)
                .background(hovering ? palette.cardHover : .clear, in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close (Esc)")
        .onHover { hovering in
            withAnimation(.spring(duration: 0.25)) { self.hovering = hovering }
        }
    }
}

/// A key, drawn like one: a lit top, a darker lip underneath.
struct Keycap: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: Theme.scaled(10.5), weight: .medium))
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                LinearGradient(colors: colorScheme == .dark
                               ? [Color(white: 0.23), Color(white: 0.18)]
                               : [palette.background, Color(white: 0.95)],
                               startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(palette.border)
            }
            .shadow(color: colorScheme == .dark ? .black : Color.black.opacity(0.12), radius: 0, y: 1.5)
    }
}

/// A labelled field, with room under it for the sentence that stops a support question.
struct Field<Content: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            // The same size as the picker's own labels beside it, so one form reads in one voice.
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
            content
            if let hint {
                Text(hint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A text field that belongs to this app rather than to the system.
///
/// `.roundedBorder` draws a light, system-styled box that reads as pasted on over a dark panel.
/// This is the same card-and-border treatment every other surface uses.
///
/// The look lives in `BupsyFieldModifier`, a `ViewModifier`, because a `TextFieldStyle` is not a
/// view: an `@Environment` property on one is not guaranteed to be resolved, and the palette's
/// default is the dark scheme, which is how a dark field could turn up in light mode. A modifier
/// reads the environment like any view. Prefer `.bupsyField()`; `BupsyFieldStyle()` is kept and
/// now just applies the modifier.
struct BupsyFieldModifier: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, 9)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(palette.border)
            }
    }
}

extension View {
    /// The app's text field look. See `BupsyFieldModifier`.
    func bupsyField() -> some View { modifier(BupsyFieldModifier()) }
}

/// The older spelling of `.bupsyField()`, kept so `.textFieldStyle(BupsyFieldStyle())` still
/// works. It holds no environment of its own; the modifier it applies does the reading.
///
/// Main-actor isolated with a `@preconcurrency` conformance: the modifier it applies is a view
/// type, and handing the field to it from a nonisolated requirement is a data race in Swift 6.
@MainActor
struct BupsyFieldStyle: @preconcurrency TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.bupsyField()
    }
}

/// The one action a dialog is really asking you to take. A wrapper over
/// `BupsyButtonStyle(kind: .primary, size: .lg)`.
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BupsyButtonStyle(kind: .primary, size: .lg).makeBody(configuration: configuration)
    }
}

/// The app's one button style, per the design's `.bp-btn`.
///
/// Radius lg, regular weight (medium on primary), at the large 44pt page-action height or the
/// 36pt in-card height. Every kind has a hover, a pressed and a disabled state: hover lifts the
/// fill a step, press sinks the button half a point, disabled fades it to half.
/// `PrimaryButton`, `QuietButton` and `ThreadButtonStyle` are thin wrappers over this.
struct BupsyButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        /// The pink one. At most one per view.
        case primary
        /// The grey fill, with a hairline so it still reads on a grey card.
        case secondary
        /// Background fill and a border.
        case outline
        /// No fill until hovered: row and inline actions.
        case ghost
        /// A red tint, never a solid red slab.
        case destructive
        /// A ghost button whose label is red, for a removal sitting among quiet actions.
        case ghostDestructive
    }

    enum Size: Equatable {
        /// 44pt: page and dialog actions.
        case lg
        /// 36pt: actions inside cards.
        case md
        /// 28pt: the smallest, for dense rows.
        case sm
        /// Any other height, for a call site that has not been moved onto a step yet.
        case custom(CGFloat)

        var height: CGFloat {
            switch self {
            case .lg: Theme.Size.controlLg
            case .md: Theme.Size.controlMd
            case .sm: Theme.Size.controlSm
            case .custom(let height): height
            }
        }

        var padding: CGFloat {
            switch self {
            case .lg: Theme.Space.gutter
            case .md: Theme.Space.step
            case .sm: Theme.Space.compact
            case .custom(let height): height >= Theme.Size.controlLg ? Theme.Space.gutter : Theme.Space.step
            }
        }
    }

    var kind: Kind = .secondary
    var size: Size = .lg

    init(kind: Kind = .secondary, size: Size = .lg) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        BupsyButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

/// The drawing behind `BupsyButtonStyle`, a view so it can read the environment and hold hover.
struct BupsyButtonBody: View {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let kind: BupsyButtonStyle.Kind
    let size: BupsyButtonStyle.Size
    @State private var hovering = false

    init(configuration: ButtonStyleConfiguration, kind: BupsyButtonStyle.Kind, size: BupsyButtonStyle.Size) {
        self.configuration = configuration
        self.kind = kind
        self.size = size
    }

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        let lit = (hovering || configuration.isPressed) && isEnabled
        configuration.label
            .font(Theme.Typography.body)
            .fontWeight(kind == .primary ? .medium : .regular)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, size.padding)
            .frame(height: size.height)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(fill(lit: lit))
                    // The design mixes 10% ink into the pink on hover. `Color.mix` is macOS 15,
                    // so the ink is laid over the pink instead, which draws the same thing.
                    if kind == .primary && lit {
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .fill(palette.foreground.opacity(0.1))
                    }
                }
            }
            .overlay {
                // The primary's lit top edge, so it reads as pressable; a hairline elsewhere.
                if kind == .primary {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear, .black.opacity(0.1)],
                                                     startPoint: .top, endPoint: .bottom))
                } else if kind == .secondary || kind == .outline {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(palette.border)
                }
            }
            .shadow(color: kind == .primary && isEnabled ? palette.primary.opacity(0.4) : .clear,
                    radius: 2, y: 1)
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(pressed ? 0.985 : 1)
            .offset(y: pressed ? 0.5 : 0)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: palette.onPrimary
        case .secondary, .outline, .ghost: palette.foreground
        case .destructive, .ghostDestructive: palette.destructiveText
        }
    }

    private func fill(lit: Bool) -> Color {
        switch kind {
        case .primary: palette.primary
        case .secondary: lit ? palette.cardHover : palette.secondary
        case .outline: lit ? palette.cardHover : palette.background
        case .ghost: lit ? palette.cardHover : Color.clear
        case .destructive: palette.destructive.opacity(lit ? 0.18 : 0.1)
        case .ghostDestructive: lit ? palette.destructive.opacity(0.1) : Color.clear
        }
    }
}

/// The app's one on/off switch, per the design's `.bp-switch`: a 36 by 20 track, ink when on
/// (pink is kept for things that need you), a grey track when off, and a white 16pt knob.
///
/// Apply it with `.bupsySwitch()` rather than relying on `.tint`: the tint only recolours the
/// system switch, which is the wrong size and goes pink under the app-wide tint.
struct BupsySwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BupsySwitchBody(configuration: configuration)
    }
}

struct BupsySwitchBody: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ToggleStyleConfiguration

    init(configuration: ToggleStyleConfiguration) {
        self.configuration = configuration
    }

    var body: some View {
        HStack(spacing: Theme.Space.step) {
            configuration.label
            Button {
                withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? palette.foreground : palette.switchOff)
                    Circle()
                        .fill(knob)
                        .overlay { Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .frame(width: 36, height: 20)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    /// White in light mode. In dark mode the "on" track is the near-white ink, so the knob takes
    /// the background colour instead, as the design's base `--background` knob does.
    private var knob: LinearGradient {
        colorScheme == .dark
            ? LinearGradient(colors: [palette.background, palette.background], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.white, Color(white: 0.925)], startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// The app's switch. See `BupsySwitchStyle`.
    func bupsySwitch() -> some View { toggleStyle(BupsySwitchStyle()) }
}

/// One option of a `Segmented` control.
struct SegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// The app's one segmented control, per the design's `.bp-seg`: two to five short options in a
/// radius-lg track; the chosen one lifts onto the background with a hairline ring and medium
/// weight. 32pt options at 13pt, so the whole control is 36 tall, the in-card control height.
/// Pass `full` to stretch the options across the width.
struct Segmented<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: Value
    let options: [SegmentedOption<Value>]
    var full: Bool
    @State private var hovered: Value?

    init(selection: Binding<Value>, options: [SegmentedOption<Value>], full: Bool = false) {
        self._selection = selection
        self.options = options
        self.full = full
    }

    /// Options built from values and a closure that names each one.
    init(selection: Binding<Value>, values: [Value], full: Bool = false, title: (Value) -> String) {
        self.init(selection: selection,
                  options: values.map { SegmentedOption($0, title($0)) },
                  full: full)
    }

    var body: some View {
        HStack(spacing: Theme.Space.hairline) {
            ForEach(options) { option in
                optionButton(option)
            }
        }
        .padding(Theme.Space.hairline)
        .background(trackColour, in: .rect(cornerRadius: Theme.Radius.lg))
        .fixedSize(horizontal: !full, vertical: true)
    }

    private func optionButton(_ option: SegmentedOption<Value>) -> some View {
        let chosen = option.value == selection
        let lit = chosen || hovered == option.value
        return Button {
            selection = option.value
        } label: {
            Text(option.title)
                .font(.system(size: Theme.scaled(13), weight: chosen ? .medium : .regular))
                .foregroundStyle(lit ? palette.foreground : palette.mutedForeground)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.step)
                .frame(maxWidth: full ? .infinity : nil)
                .frame(height: 32)
                .background(chosen ? chosenColour : Color.clear,
                            in: .rect(cornerRadius: Theme.Radius.md))
                .overlay {
                    if chosen {
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(palette.border)
                    }
                }
                .shadow(color: chosen ? Color.black.opacity(0.06) : .clear, radius: 1, y: 1)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = option.value } else if hovered == option.value { hovered = nil }
        }
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .animation(.easeOut(duration: 0.12), value: chosen)
    }

    /// Light: a grey card track with the chosen option on white. Dark: the design's override, a
    /// sidebar-dark track with the chosen option on the hover grey, so it still lifts.
    private var trackColour: Color { colorScheme == .dark ? palette.sidebar : palette.card }
    private var chosenColour: Color { colorScheme == .dark ? palette.cardHover : palette.background }
}

/// A row that states a number rather than offering a choice.
struct FactRow: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Rectangle().fill(palette.border).frame(height: 1)
                    .padding(.leading, Theme.Space.step)
            }
            HStack {
                Text(label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                Spacer(minLength: Theme.Space.snug)
                Text(value)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                    .monospacedDigit()
            }
            .padding(.horizontal, Theme.Space.step)
            .frame(height: 36)
        }
    }
}

/// How much of one subscription window is gone, as reported by the engine.
///
/// A bar rather than a number alone: "73%" needs reading, a bar that is nearly full does not. The
/// reset time matters as much as the figure — being near a limit is only alarming if it does not
/// reset in ten minutes.
struct LimitBar: View {
    @Environment(\.palette) private var palette
    let name: String
    let window: RateLimit.Window
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Rectangle().fill(palette.border).frame(height: 1)
                    .padding(.leading, Theme.Space.step)
            }
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack {
                    Text(name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                    Spacer(minLength: Theme.Space.snug)
                    Text("\(LimitScale.percent(window.utilization))%")
                        .font(Theme.Typography.body)
                        .foregroundStyle(tone)
                        .monospacedDigit()
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.secondary)
                        Capsule()
                            .fill(tone)
                            // Clamped: an engine reporting over 1.0 during an overage must not
                            // draw a bar wider than its track.
                            .frame(width: geometry.size.width
                                   * min(max(window.utilization, 0), 1))
                    }
                }
                .frame(height: 4)

                if let resets = window.resetsAt {
                    Text("Resets \(resets.formatted(.relative(presentation: .named)))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.step)
        }
    }

    /// Only coloured once it is worth noticing. Everything red all the time teaches people to
    /// ignore red. The one scale every limit readout uses: see `LimitScale`.
    private var tone: Color {
        LimitScale.fill(window.utilization, palette)
    }
}

/// A soft fade at the top of a thread, under its floating title pill, so messages scrolling up
/// pass behind the pill instead of being legible right through and around it.
struct TopFade: View {
    @Environment(\.palette) private var palette
    var body: some View {
        LinearGradient(colors: [palette.background, palette.background.opacity(0)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 76)
            .allowsHitTesting(false)
    }
}

/// Nothing here yet: a bot napping on the spot, one line of why, at most one way forward.
///
/// Grey and asleep by default. When empty is good news (nothing waiting on you), pass `.done` and
/// a colour so the bot cheers instead.
struct EmptyState<Action: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var message: String?
    var mood: BotMood = .sleeping
    /// Index into the bot colours; nil is the neutral grey bot.
    var colour: Int?
    var faceSize: CGFloat = 72
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Theme.Space.snug) {
            Group {
                if let colour {
                    BotFace(hue: 0, mood: mood, size: faceSize, shape: .bup, colour: colour)
                } else {
                    BotFace(hue: 0, mood: mood, size: faceSize, shape: .bup, colour: 0)
                        .saturation(0)
                        .opacity(0.7)
                }
            }
            .padding(.bottom, Theme.Space.tight)
            .accessibilityHidden(true)

            Text(title)
                .font(Theme.Typography.heading)
                .foregroundStyle(palette.foreground)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action.padding(.top, Theme.Space.tight)
        }
        .padding(Theme.Space.section)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(title: String, message: String? = nil, mood: BotMood = .sleeping, colour: Int? = nil,
         faceSize: CGFloat = 72) {
        self.init(title: title, message: message, mood: mood, colour: colour, faceSize: faceSize) {
            EmptyView()
        }
    }
}
