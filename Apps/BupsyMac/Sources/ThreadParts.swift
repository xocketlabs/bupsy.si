import BupsyKit
import SwiftUI

/// The measurements a conversation is laid out on, taken from the design's Message component.
///
/// A bot's reply leads with a 28pt face and a 12pt gap, so everything that belongs to that reply
/// (tool lines, cards, the thinking line) sits 40pt in, under the words rather than under the face.
enum ThreadLayout {
    static let avatar: CGFloat = 28
    static let avatarGap: CGFloat = 12
    static var gutter: CGFloat { avatar + avatarGap }
    /// max-w-4xl, the column the transcript and the composer share.
    static let columnMaxWidth: CGFloat = 896
    /// Cards in a thread stop here so a wide window does not stretch a decision into a banner.
    static let cardMaxWidth: CGFloat = 640
    static let messageFont = Font.system(size: Theme.scaled(14))
    static let metaFont = Font.system(size: Theme.scaled(12.5))
    static let monoFont = Font.system(size: Theme.scaled(11.5), design: .monospaced)
}

/// A small status pill for the topbar: tone-washed, optionally led by a dot.
struct ThreadStatusBadge: View {
    @Environment(\.palette) private var palette
    let text: String
    var tone: Color?
    var dot = false

    var body: some View {
        let colour = tone ?? palette.mutedForeground
        HStack(spacing: 6) {
            if dot {
                Circle().fill(colour).frame(width: 6, height: 6)
            }
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(colour)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(colour.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.control))
    }
}

/// The buttons a thread uses, at the design's 36pt in-card size.
struct ThreadButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, ghostDestructive }

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var kind: Kind = .secondary
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.body)
            .fontWeight(kind == .primary ? .medium : .regular)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost || kind == .ghostDestructive ? 10 : 14)
            .frame(height: height)
            .background(background(pressed: configuration.isPressed),
                        in: .rect(cornerRadius: Theme.Radius.control))
            .shadow(color: kind == .primary && isEnabled ? palette.primary.opacity(0.35) : .clear,
                    radius: 2, y: 1)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(.rect)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary, .ghost: palette.foreground
        case .ghostDestructive: palette.destructiveText
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: palette.primary.opacity(pressed ? 0.85 : 1)
        case .secondary: pressed ? palette.cardHover : palette.card
        case .ghost, .ghostDestructive: pressed ? palette.cardHover : .clear
        }
    }
}

/// agndex's nested card: a lip around an inner card, with a quiet footer living on the lip.
///
/// The lip is passed in, so an approval can wear pink and a question plain grey, in the same
/// shape. `wash` is laid over `base`, which is how a tint "mixed into" a surface is drawn without
/// `Color.mix`.
struct ThreadNestedCard<Content: View, Footer: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let base: Color
    var wash: Color?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            VStack(alignment: .leading, spacing: Theme.Space.step) { content }
                .padding(Theme.Space.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colorScheme == .dark ? palette.card : palette.background,
                            in: .rect(cornerRadius: Theme.Radius.base))
            footer
                .padding(.horizontal, Theme.Space.step)
        }
        .padding([.top, .horizontal], 2)
        .padding(.bottom, Theme.Space.step)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.bubble).fill(base)
                if let wash {
                    RoundedRectangle(cornerRadius: Theme.Radius.bubble).fill(wash)
                }
            }
        }
        .frame(maxWidth: ThreadLayout.cardMaxWidth, alignment: .leading)
    }
}

/// A bot peeking over the top edge of the composer while it works, paws on the rim.
///
/// The same idea as `SheetFrame`'s peek, at the composer's smaller size: the face is cut off
/// below the eyes so it reads as hiding behind the box, and the two paws are drawn in front of
/// the rim so it is clearly holding on.
struct ThreadComposerPeek: View {
    let bot: Bot

    init(bot: Bot) { self.bot = bot }

    /// How much of the face shows above the rim.
    private let visible: CGFloat = 30
    private let size: CGFloat = 44

    var body: some View {
        ZStack(alignment: .topLeading) {
            BotFace(bot: bot, mood: .working, size: size)
                .frame(width: size, height: visible, alignment: .top)
                .clipped()
            paw(x: 7, angle: -6)
            paw(x: 27, angle: 6)
        }
        .frame(width: size, height: visible + 4, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func paw(x: CGFloat, angle: Double) -> some View {
        let index = (bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue)) % BotShape.rgbPalette.count
        let tint = BotShape.rgbPalette[index]
        let fill = LinearGradient(colors: [tint.mixed(with: .hex(0xFFFFFF), 0.62).color, tint.color],
                                  startPoint: .top, endPoint: .bottom)
        let rim = tint.mixed(with: .hex(0x000000), 0.72).color.opacity(0.5)
        return UnevenRoundedRectangle(cornerRadii: .init(topLeading: 6, bottomLeading: 4,
                                                         bottomTrailing: 4, topTrailing: 6))
            .fill(fill)
            .shadow(color: rim, radius: 0.5, y: 1)
            .frame(width: 10, height: 7)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: visible - 3)
    }
}
