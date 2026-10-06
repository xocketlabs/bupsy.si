import BupsyKit
import SwiftUI

// The shared shape of the setup pages (Apps, Usage, Permissions, Machines): a page header, then
// sections that each open with an icon heading and hold rows on lifted cards. Prefixed `Setup` so
// they cannot collide with pieces other screens define.

/// The scrolling column every setup page sits in: max-w-896, 24 on top, 32 at the sides.
struct SetupPageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.page) {
                content
            }
            .padding(.horizontal, Theme.Space.pageSide)
            .padding(.top, Theme.Space.section)
            .padding(.bottom, Theme.Space.page)
            .frame(maxWidth: Theme.Size.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// A page's title and the sentence under it, with room on the right for one control.
struct SetupPageHeader<Trailing: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    let description: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.gutter) {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text(title)
                    .font(Theme.Typography.title)
                    .tracking(-0.4)
                    .foregroundStyle(palette.foreground)
                Text(description)
                    .font(Theme.Typography.lead)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension SetupPageHeader where Trailing == EmptyView {
    init(title: String, description: String) {
        self.init(title: title, description: description) { EmptyView() }
    }
}

/// The tones a status badge can take.
enum SetupTone {
    case success, warning, destructive, info, neutral

    func colour(_ palette: Palette.Scheme) -> Color {
        badgeTone.text(palette)
    }

    /// The `Badge` tone this maps to.
    var badgeTone: BadgeTone {
        switch self {
        case .success: .success
        case .warning: .warning
        case .destructive: .destructive
        case .info: .info
        case .neutral: .neutral
        }
    }
}

/// A small status pill: "Connected", "Needs LINEAR_API_KEY", "Failed to start". A thin wrapper
/// over `Badge`.
struct SetupBadge: View {
    let text: String
    var tone: SetupTone = .neutral
    /// A live dot in front, for states that are actively on (connected, running).
    var dot = false

    var body: some View {
        Badge(text: text, tone: tone.badgeTone, dot: dot)
    }
}

/// A section's heading: icon, title, an optional badge, and a line of why underneath.
struct SetupSectionHeader: View {
    @Environment(\.palette) private var palette
    let icon: String
    let title: String
    var badge: String?
    var badgeTone: SetupTone = .info
    var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(13), weight: .medium))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 18)
                Text(title)
                    .font(Theme.Typography.heading)
                    .foregroundStyle(palette.foreground)
                if let badge { SetupBadge(text: badge, tone: badgeTone) }
            }
            if let description {
                Text(description)
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.leading, 26)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One lifted row: a tile or a face, a title, a meta line of facts separated by dots, then
/// whatever the row offers on the right.
struct SetupListRow<Leading: View, Trailing: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var meta: [String] = []
    /// Index into `meta` to draw in a warning tone, for the one fact that needs doing.
    var flaggedMeta: Int?
    var monospacedMeta: Int?
    let leading: Leading
    let trailing: Trailing
    @State private var hovering = false

    init(title: String, meta: [String] = [], flaggedMeta: Int? = nil, monospacedMeta: Int? = nil,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.meta = meta
        self.flaggedMeta = flaggedMeta
        self.monospacedMeta = monospacedMeta
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Space.gutter) {
            leading
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                if !meta.isEmpty {
                    HStack(spacing: Theme.Space.snug) {
                        ForEach(Array(meta.enumerated()), id: \.offset) { index, item in
                            if index > 0 { MetaDot() }
                            Text(item)
                                .font(index == monospacedMeta
                                      ? .system(size: Theme.scaled(11), design: .monospaced)
                                      : Theme.Typography.caption)
                                .foregroundStyle(index == flaggedMeta
                                                 ? palette.warning : palette.mutedForeground)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, Theme.Space.step)
        .padding(.leading, Theme.Space.step)
        .padding(.trailing, Theme.Space.gutter)
        .background(hovering ? palette.cardHover : palette.card,
                    in: .rect(cornerRadius: Theme.Radius.xl, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A square icon-only action at the end of a row, at the small control size (28pt, which is also
/// its hit area). Red for anything that removes. Always carries its words as help and as the
/// VoiceOver label, since the icon alone says nothing to a screen reader.
struct SetupIconButton: View {
    @Environment(\.palette) private var palette
    let systemName: String
    let help: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    init(systemName: String, help: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Theme.scaled(12), weight: .semibold))
                .foregroundStyle(destructive ? palette.destructiveText : palette.foreground)
                .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                .background(hovering ? palette.background.opacity(0.7) : Color.clear,
                            in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// A raised inner panel sitting in a grey card, with a quiet footer line on the card's lip.
struct SetupPanel<Content: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let footer: String?
    let content: Content

    init(footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(Theme.Space.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colorScheme == .dark ? palette.card : palette.background,
                            in: .rect(cornerRadius: innerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                        .strokeBorder(palette.border)
                }
            if let footer {
                Text(footer)
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.vertical, Theme.Space.compact)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.hairline)
        .background(colorScheme == .dark ? palette.sidebar : palette.card,
                    in: .rect(cornerRadius: Theme.Radius.xl, style: .continuous))
    }

    /// Concentric with the lip: the outer radius less the lip's width.
    private var innerRadius: CGFloat { Theme.Radius.xl - Theme.Space.hairline }
}

/// A short "nothing here" line with a napping bot beside it, for an empty section inside a page
/// that has other things on it. Asleep and held still, the compact form of `EmptyState`, so an
/// empty section reads as calm rather than as a bot waiting for something. A whole empty page
/// uses `EmptyState` instead.
struct SetupEmptyNote: View {
    @Environment(\.palette) private var palette
    let text: String
    var mood: BotMood = .sleeping

    var body: some View {
        HStack(spacing: Theme.Space.gutter) {
            BotFace(hue: 0, mood: mood, size: 48, shape: .bup, colour: 0, still: true)
                .saturation(0)
                .opacity(0.7)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.gutter)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.xl, style: .continuous))
    }
}

/// The hairline between a page's major sections.
struct SetupSectionRule: View {
    @Environment(\.palette) private var palette
    var body: some View { Rectangle().fill(palette.border).frame(height: 1) }
}

/// A small sentence after the last section, saying the one thing people would otherwise ask.
struct SetupFootnote: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.label)
            .foregroundStyle(palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}
