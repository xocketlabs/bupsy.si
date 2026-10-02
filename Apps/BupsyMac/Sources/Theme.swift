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

/// A pill of secondary information: an icon and a short label at control height.
struct MetaChip: View {
    @Environment(\.palette) private var palette
    let icon: String
    let text: String
    var emphasised = false

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: icon).font(.system(size: 12))
            Text(text).font(Theme.Typography.body)
        }
        .foregroundStyle(emphasised ? palette.foreground : palette.mutedForeground)
        .padding(.horizontal, Theme.Space.step)
        .frame(height: Theme.Size.control)
        .background(palette.secondary, in: .rect(cornerRadius: Theme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(palette.border)
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
