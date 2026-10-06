import SwiftUI

// The tinted, dotted ground the mascot performs on: the onboarding stage and the bot creator's
// preview card both stand a bot on it. Small pieces, prefixed so they cannot collide.

/// A grid of faint dots, drawn once per size change rather than as hundreds of views.
struct MascotStageDots: View {
    @Environment(\.palette) private var palette
    var spacing: CGFloat = 20
    var radius: CGFloat = 1.5

    var body: some View {
        let colour = palette.foreground.opacity(0.09)
        let step = spacing
        let dot = radius
        Canvas { context, size in
            var path = Path()
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
                    x += step
                }
                y += step
            }
            context.fill(path, with: .color(colour))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The stage itself: the page colour washed in one tint, with the dots on top.
struct MascotStageBackground: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color
    var cornerRadius: CGFloat = 0

    var body: some View {
        ZStack {
            palette.background
            tint.opacity(colorScheme == .dark ? 0.16 : 0.13)
            MascotStageDots()
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A soft spotlight behind whoever is on stage.
struct MascotStageGlow: View {
    @Environment(\.palette) private var palette
    let tint: Color
    var diameter: CGFloat = 320

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [palette.background.opacity(0.75), tint.opacity(0.08), .clear],
                                 center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// What the mascot is saying: a rounded bubble with a little tail pointing down at it.
struct MascotStageBubble: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Theme.scaled(14)))
            .foregroundStyle(palette.foreground)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(fill, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottom) {
                MascotStageBubbleTail()
                    .fill(fill)
                    .frame(width: 14, height: 7)
                    .offset(y: 6.5)
            }
            .compositingGroup()
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 6, y: 2)
    }

    private var fill: Color { colorScheme == .dark ? palette.popover : palette.background }
}

/// The bubble's tail: a small downward triangle.
struct MascotStageBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
