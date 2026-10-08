import SwiftUI

/// "● Bupsy": the pink dot and the name, as on the web app and the site.
struct Wordmark: View {
    @Environment(\.palette) private var palette
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: size * 0.35) {
            Circle().fill(palette.primary).frame(width: size * 0.5, height: size * 0.5)
            Text("Bupsy")
                .font(.system(size: size, weight: .heavy))
                .tracking(-size * 0.025)
        }
        .accessibilityElement()
        .accessibilityLabel("Bupsy")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A bot's initial in its own colour. Bupsy's mascot faces are drawn on the Mac; the phone keeps
/// to the colour, which is what tells bots apart at a glance.
struct Avatar: View {
    @Environment(\.palette) private var palette
    let bot: Bot
    let size: CGFloat

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1)
            .frame(width: size, height: size)
            .background(Palette.colour(hex: bot.colour) ?? palette.mutedForeground, in: Circle())
            .accessibilityHidden(true)
    }

    private var initial: String {
        bot.name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

/// Three dots that breathe while a bot works.
struct WorkingDots: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var dot: CGFloat = 5

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: dot * 0.6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(palette.mutedForeground)
                        .frame(width: dot, height: dot)
                        .opacity(reduceMotion ? 0.7 : Self.breath(time, delay: Double(index) * 0.15))
                }
            }
        }
        .accessibilityLabel("Working")
    }

    /// The web app's `breathe`: faint, a swell at 40% of each 1.2-second cycle, faint again.
    private static func breath(_ time: TimeInterval, delay: Double) -> Double {
        let phase = ((time - delay).truncatingRemainder(dividingBy: 1.2) + 1.2).truncatingRemainder(dividingBy: 1.2) / 1.2
        let rise = phase < 0.4 ? phase / 0.4 : phase < 0.8 ? (0.8 - phase) / 0.4 : 0
        return 0.25 + 0.75 * rise
    }
}

/// The two kinds of button the app has: the one pink action, and everything else.
struct BupsyButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var kind: Kind = .secondary
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(kind == .primary ? palette.onPrimary : palette.foreground)
            .background(kind == .primary ? palette.primary : palette.cardHover,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == BupsyButtonStyle {
    static var bupsyPrimary: BupsyButtonStyle { BupsyButtonStyle(kind: .primary) }
    static var bupsySecondary: BupsyButtonStyle { BupsyButtonStyle(kind: .secondary) }
}

/// A short message that floats over the screen and goes away on its own.
struct Toast: View {
    @Environment(\.palette) private var palette
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(palette.background)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.foreground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Says a Mac can't be reached, without taking the screen away: what's there is still useful.
struct OfflineBanner: View {
    @Environment(\.palette) private var palette
    var text = "Can't reach your Mac. Retrying…"

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(palette.warning).frame(width: 8, height: 8)
            Text(text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.border))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
