import Foundation
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

/// A name tag under someone on stage: a white capsule with a dot in their colour.
struct MascotStageTag: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var dot: Color? = nil
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: Theme.scaled(compact ? 12 : 13), weight: .medium))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 4 : 6)
        .background(colorScheme == .dark ? palette.popover : palette.background, in: Capsule())
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06), radius: 3, y: 1)
    }
}

/// A lit spot on the floor for whoever is being presented: a soft ellipse in their colour.
struct MascotStageSpot: View {
    let tint: Color
    var width: CGFloat = 200

    var body: some View {
        Ellipse()
            .fill(RadialGradient(colors: [tint.opacity(0.35), tint.opacity(0.12), .clear],
                                 center: .center, startRadius: 0, endRadius: width / 2))
            .frame(width: width, height: width * 0.22)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A short dashed line joining two things on stage, vertical or horizontal.
struct MascotStageDash: View {
    let tint: Color
    var length: CGFloat = 24
    var vertical = true

    var body: some View {
        Path { path in
            if vertical {
                path.move(to: CGPoint(x: 1, y: 0))
                path.addLine(to: CGPoint(x: 1, y: length))
            } else {
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: length, y: 1))
            }
        }
        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        .frame(width: vertical ? 2 : length, height: vertical ? length : 2)
        .accessibilityHidden(true)
    }
}

/// A bot peeking over the top edge of something: only the top of its face shows.
struct MascotStagePeek: View {
    let shape: BotShape
    let colour: Int
    var size: CGFloat = 64

    var body: some View {
        BotFace(hue: 0.5, mood: .idle, size: size, shape: shape, colour: colour)
            .frame(width: size, height: size * 0.58, alignment: .top)
            .clipped()
            .accessibilityHidden(true)
    }
}

/// Confetti scattered around the stage, in the eight bot colours. Pieces drift in once when it
/// appears and then hold still, so it celebrates without becoming noise.
struct MascotStageConfetti: View {
    var count: Int
    @State private var landed = false

    init(count: Int = 18) {
        self.count = count
    }

    private struct Piece {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let round: Bool
        let colour: Int
        let angle: Double
    }

    /// Spread on a golden-angle spiral so the pieces look scattered without being random,
    /// which keeps the scene the same every time it is drawn.
    private var pieces: [Piece] {
        (0..<count).map { index in
            let angle = Double(index) * 137.5
            let radius = Double(28 + (index * 53) % 18)
            let radians = angle * Double.pi / 180
            let round = index % 3 == 0
            return Piece(x: CGFloat(0.5 + cos(radians) * radius * 1.25 / 100),
                         y: CGFloat(0.46 + sin(radians) * radius / 100),
                         width: round ? 8 : 6, height: round ? 8 : 13, round: round,
                         colour: index % BotShape.palette.count,
                         angle: Double((index * 47) % 180))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                RoundedRectangle(cornerRadius: piece.round ? piece.width / 2 : 2, style: .continuous)
                    .fill(BotShape.palette[piece.colour])
                    .frame(width: piece.width, height: piece.height)
                    .rotationEffect(.degrees(landed ? piece.angle : piece.angle - 60))
                    .position(x: geometry.size.width * piece.x,
                              y: geometry.size.height * piece.y - (landed ? 0 : 28))
                    .opacity(landed ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { landed = true }
        }
    }
}
