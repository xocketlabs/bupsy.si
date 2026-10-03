import SwiftUI

/// bupsy's mark: a bubble with a face, and a smaller bubble floating beside it.
///
/// The bots are plush characters now, so the app's own mark is one of them — the one that looks
/// after the others — rather than the gradient square it used to be, which said nothing and could
/// have belonged to any app. "Bupsy" sounds like a bubble, so it is one: the same glossy bead eyes
/// as every bot, in the brand's pink-to-violet, with a little companion bubble rising off it.
///
/// Drawn rather than shipped as an image so the sidebar mark, the app icon and anything else stay
/// one drawing at every size. `alive` lets it blink in the sidebar; the icon is rendered still.
struct BupsyMark: View {
    var size: CGFloat = 24
    var alive = false

    var body: some View {
        if alive {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                canvas(time: timeline.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: size, height: size)
        } else {
            canvas(time: 0).frame(width: size, height: size)
        }
    }

    private func canvas(time: TimeInterval) -> some View {
        Canvas { context, canvas in
            Self.draw(in: &context, unit: min(canvas.width, canvas.height), time: time,
                      alive: alive)
        }
        .accessibilityLabel("bupsy")
    }

    static let pink = Color(red: 0.95, green: 0.38, blue: 0.78)
    static let violet = Color(red: 0.49, green: 0.31, blue: 0.97)
    static let ink = Color(red: 0.08, green: 0.07, blue: 0.13)

    static func draw(in context: inout GraphicsContext, unit: CGFloat, time: TimeInterval,
                     alive: Bool) {
        // The main bubble: round, a little wider than tall, sitting low so the companion bubble
        // has room above it.
        let body = CGRect(x: unit * 0.06, y: unit * 0.22, width: unit * 0.76, height: unit * 0.72)
        let shape = Ellipse().path(in: body)

        context.fill(shape, with: .linearGradient(
            Gradient(colors: [pink, violet]),
            startPoint: CGPoint(x: body.minX, y: body.minY),
            endPoint: CGPoint(x: body.maxX, y: body.maxY)))
        context.drawLayer { layer in
            layer.clip(to: shape)
            // Plush shading, the same light as the bots: soft highlight top left, shade bottom right.
            layer.fill(shape, with: .radialGradient(
                Gradient(colors: [.white.opacity(0.4), .white.opacity(0)]),
                center: CGPoint(x: body.minX + body.width * 0.3, y: body.minY + body.height * 0.22),
                startRadius: 0, endRadius: body.width * 0.6))
            layer.fill(shape, with: .radialGradient(
                Gradient(colors: [.black.opacity(0), .black.opacity(0.25)]),
                center: CGPoint(x: body.minX + body.width * 0.4, y: body.minY + body.height * 0.3),
                startRadius: body.width * 0.36, endRadius: body.width * 0.82))
        }
        // A bubble's rim highlight — the curve of light that makes it read as a bubble rather
        // than a ball.
        var rim = Path()
        rim.addArc(center: CGPoint(x: body.midX, y: body.midY), radius: body.width * 0.4,
                   startAngle: .degrees(200), endAngle: .degrees(250), clockwise: false)
        context.stroke(rim, with: .color(.white.opacity(0.7)),
                       style: StrokeStyle(lineWidth: unit * 0.035, lineCap: .round))

        // Eyes: the bots' glossy beads, glancing up toward the companion bubble.
        let openness: CGFloat = {
            guard alive else { return 1 }
            let local = (time + 1.3).truncatingRemainder(dividingBy: 5.2)
            return local < 0.16 ? CGFloat(abs(cos(local / 0.16 * .pi))) : 1
        }()
        let eyeWidth = unit * 0.095, eyeHeight = unit * 0.165
        for x in [0.38, 0.56] {
            let centre = CGPoint(x: body.minX + body.width * x + unit * 0.02,
                                 y: body.minY + body.height * 0.46)
            let rect = CGRect(x: centre.x - eyeWidth / 2,
                              y: centre.y - eyeHeight * openness / 2,
                              width: eyeWidth, height: max(eyeHeight * openness, unit * 0.012))
            context.fill(Ellipse().path(in: rect), with: .color(ink))
            if openness > 0.5 {
                let shine = max(unit * 0.034, 1)
                context.fill(Circle().path(in: CGRect(
                    x: centre.x - eyeWidth * 0.15 - shine / 2,
                    y: centre.y - eyeHeight * 0.24 - shine / 2,
                    width: shine, height: shine)), with: .color(.white.opacity(0.95)))
            }
        }

        // The companion bubble, rising off the top right. It bobs very gently when alive.
        let bob = alive ? CGFloat(sin(time * 1.6)) * unit * 0.012 : 0
        let small = CGRect(x: unit * 0.68, y: unit * 0.06 + bob, width: unit * 0.24, height: unit * 0.24)
        let bubble = Ellipse().path(in: small)
        context.fill(bubble, with: .linearGradient(
            Gradient(colors: [pink.opacity(0.95), violet.opacity(0.95)]),
            startPoint: CGPoint(x: small.minX, y: small.minY),
            endPoint: CGPoint(x: small.maxX, y: small.maxY)))
        context.fill(Circle().path(in: CGRect(
            x: small.minX + small.width * 0.22, y: small.minY + small.height * 0.2,
            width: small.width * 0.26, height: small.height * 0.26)),
            with: .color(.white.opacity(0.75)))
    }
}

/// The app icon: the mark on a dark, softly lit tile in macOS's own icon proportions.
///
/// Drawn at 1024 and scaled down for every slot, so the Dock, Finder and the menu bar all show the
/// same character the sidebar does.
struct BupsyAppIcon: View {
    var body: some View {
        ZStack {
            // macOS icons sit on a rounded tile inset from the canvas edge, not full bleed.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.16, green: 0.14, blue: 0.21),
                             Color(red: 0.07, green: 0.07, blue: 0.09)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            // A faint glow behind the character, in its own colours.
            Circle()
                .fill(RadialGradient(
                    colors: [BupsyMark.violet.opacity(0.45), .clear],
                    center: .center, startRadius: 0, endRadius: 330))
                .frame(width: 660, height: 660)
            BupsyMark(size: 560)
                .offset(x: 10, y: 6)
        }
        .frame(width: 1024, height: 1024)
    }
}
