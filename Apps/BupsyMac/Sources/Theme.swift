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
        static let rosterAvatar: CGFloat = 36
        static let bubbleAvatar: CGFloat = 24
        static let profileAvatar: CGFloat = 72
        /// max-w-4xl. Content stops here however wide the window is; a line of text that spans a
        /// display is hard to read and stops looking composed.
        static let contentMaxWidth: CGFloat = 820
        static let bubbleMaxWidth: CGFloat = 560
    }

    /// Agndex leans on small, tight-tracked type rather than many sizes.
    enum Typography {
        static let title = Font.system(size: 22, weight: .semibold)
        static let heading = Font.system(size: 15, weight: .medium)
        static let body = Font.system(size: 13)
        static let label = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let badge = Font.system(size: 10, weight: .medium)
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
                    Image(systemName: icon).font(.system(size: 12))
                }
                Text(text)
                    .font(Theme.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !compact {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
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
            Image(systemName: icon).font(.system(size: 12))
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
                        .font(.system(size: 13))
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
                        .font(.system(size: 11))
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

/// The frame every dialog in the app wears.
///
/// Sheets had been hand-assembled one at a time, so each had its own padding, its own idea of
/// where the buttons go, and the system's blue accent on a pink-accented app. A dialog is the one
/// place where inconsistency is most obvious, because you see two of them in a row.
///
/// Title at the top, content in the middle, actions in a footer behind a rule. The footer is a
/// separate band so the primary action sits in the same place in every dialog — you learn where
/// "the button" is once.
struct SheetFrame<Content: View, Actions: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    var width: CGFloat = 420
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.heading)
                    .foregroundStyle(palette.foreground)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.Space.section)
            .padding(.top, Theme.Space.section)
            .padding(.bottom, Theme.Space.gutter)

            VStack(alignment: .leading, spacing: Theme.Space.gutter) { content }
                .padding(.horizontal, Theme.Space.section)
                .padding(.bottom, Theme.Space.section)

            Rectangle().fill(palette.border).frame(height: 1)

            HStack(spacing: Theme.Space.snug) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.horizontal, Theme.Space.section)
            .padding(.vertical, Theme.Space.gutter)
            .background(palette.sidebar)
        }
        .frame(width: width)
        .background(palette.popover)
        // The app's own accent, so focus rings and default buttons stop arriving in system blue.
        .tint(palette.primary)
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
            Text(label)
                .font(Theme.Typography.caption)
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
                    ? palette.primary.opacity(configuration.isPressed ? 0.78 : 1)
                    : palette.secondary,
                in: .rect(cornerRadius: Theme.Radius.control))
    }
}
