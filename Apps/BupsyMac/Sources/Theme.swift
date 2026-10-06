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
    }

    enum Radius {
        /// rounded-lg — chips, buttons, icon tiles.
        static let control: CGFloat = 8
        /// The base radius.
        static let base: CGFloat = 10
        /// rounded-xl — cards and rows.
        static let card: CGFloat = 12
        static let bubble: CGFloat = 14
    }

    enum Size {
        /// h-11. Every control lands on this height, which is what makes a row of mixed
        /// buttons, chips and fields look deliberate rather than assembled.
        static let control: CGFloat = 44
        /// size-11 — the square tile that leads a card row.
        static let tile: CGFloat = 44
        static let rosterAvatar: CGFloat = Theme.scaled(36)
        static let bubbleAvatar: CGFloat = Theme.scaled(24)
        static let profileAvatar: CGFloat = 72
        /// max-w-4xl. Content stops here however wide the window is; a line of text that spans a
        /// display is hard to read and stops looking composed.
        static let contentMaxWidth: CGFloat = 820
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

/// A small coloured label. Violet by default, which is Agndex's "informational" tone.
struct Badge: View {
    @Environment(\.palette) private var palette
    let text: String
    var tone: Color?

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(tone ?? palette.info)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 5)
            .background((tone ?? palette.info).opacity(0.12),
                        in: .rect(cornerRadius: Theme.Radius.control))
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
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .padding(.horizontal, 2)

            VStack(spacing: 0) { content }
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
struct BupsyFieldStyle: TextFieldStyle {
    @Environment(\.palette) private var palette

    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, 9)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(palette.border)
            }
    }
}

/// The one action a dialog is really asking you to take.
struct PrimaryButton: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.body)
            .fontWeight(.medium)
            // Dark text on the accent: the accent is a light pink, and white on it fails to
            // separate at this size.
            .foregroundStyle(isEnabled ? Color.black.opacity(0.85) : palette.mutedForeground)
            .padding(.horizontal, Theme.Space.gutter)
            .frame(height: Theme.Size.control)
            .background(
                isEnabled
                    ? palette.primary.opacity(configuration.isPressed ? 0.85 : 1)
                    : palette.secondary,
                in: .rect(cornerRadius: Theme.Radius.control))
            // A lit top edge and a soft drop in its own colour: the button reads as pressable.
            .overlay {
                if isEnabled {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .clear, .black.opacity(0.08)],
                                                     startPoint: .top, endPoint: .bottom))
                }
            }
            .shadow(color: isEnabled ? palette.primary.opacity(0.35) : .clear, radius: 2, y: 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
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
                    Text("\(Int((window.utilization * 100).rounded()))%")
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
    /// ignore red.
    private var tone: Color {
        switch window.utilization {
        case 0.9...: palette.destructive
        case 0.7...: .orange
        default: palette.mutedForeground
        }
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
