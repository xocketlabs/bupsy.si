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

        // Cheeks and a small smile, only where there are pixels enough to read them: at sidebar
        // size they turn into smudges, at icon size they are what makes it a character.
        if unit >= 96 {
            for x in [0.27, 0.70] {
                let cheek = CGRect(x: body.minX + body.width * x - unit * 0.05,
                                   y: body.minY + body.height * 0.62 - unit * 0.025,
                                   width: unit * 0.1, height: unit * 0.05)
                context.fill(Ellipse().path(in: cheek.insetBy(dx: -unit * 0.02, dy: -unit * 0.012)),
                             with: .radialGradient(
                                Gradient(colors: [Color(red: 1, green: 0.45, blue: 0.7).opacity(0.75),
                                                  Color(red: 1, green: 0.45, blue: 0.7).opacity(0)]),
                                center: CGPoint(x: cheek.midX, y: cheek.midY),
                                startRadius: 0, endRadius: unit * 0.07))
            }
            var smile = Path()
            let mouth = CGPoint(x: body.minX + body.width * 0.47 + unit * 0.02,
                                y: body.minY + body.height * 0.63)
            smile.move(to: CGPoint(x: mouth.x - unit * 0.035, y: mouth.y))
            smile.addQuadCurve(to: CGPoint(x: mouth.x + unit * 0.035, y: mouth.y),
                               control: CGPoint(x: mouth.x, y: mouth.y + unit * 0.04))
            context.stroke(smile, with: .color(ink),
                           style: StrokeStyle(lineWidth: unit * 0.018, lineCap: .round))
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

/// The app icon: three of the roster's own bots huddled together, with bupsy's bubbles rising
/// above them.
///
/// bupsy is a roster, not one assistant, so the icon is a group — drawn with the same `BotFace`
/// code the sidebar uses, so the icon's characters are the app's characters. Every face is kept
/// clear of the others: at Dock size a half-hidden face reads as a smudge. Drawn at 1024 and scaled
/// down for every slot.
struct BupsyAppIcon: View {
    private let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)

    var body: some View {
        ZStack {
            // macOS icons sit on a rounded tile inset from the canvas edge, not full bleed.
            tile.fill(LinearGradient(
                    colors: [Color(red: 1, green: 0.96, blue: 0.99), Color(red: 0.91, green: 0.87, blue: 1)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(tile.fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                  startPoint: .top, endPoint: .center)))
                .overlay(tile.strokeBorder(.white.opacity(0.5), lineWidth: 4))
                .frame(width: 824, height: 824)
            ZStack {
                floor(width: 300, opacity: 0.22).offset(x: -235, y: 250)
                floor(width: 300, opacity: 0.22).offset(x: 235, y: 250)
                StillBotFace(shape: .ghost, colour: 3, size: 330)
                    .rotationEffect(.degrees(-8)).offset(x: -235, y: 110)
                StillBotFace(shape: .cat, colour: 5, size: 330)
                    .rotationEffect(.degrees(8)).offset(x: 235, y: 110)
                floor(width: 400, opacity: 0.3).offset(y: 260)
                StillBotFace(shape: .circle, colour: 8, size: 440).offset(y: 50)
                bubble(110).offset(x: 150, y: -265)
                bubble(56).offset(x: 230, y: -335)
            }
            .mask(tile.frame(width: 824, height: 824))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .frame(width: 1024, height: 1024)
    }

    /// A soft shadow on the floor of the tile, so the bots stand rather than float.
    private func floor(width: CGFloat, opacity: Double) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [.black.opacity(opacity), .clear], center: .center,
                                 startRadius: 0, endRadius: width / 2))
            .frame(width: width, height: width * 0.22)
    }

    /// bupsy's bubble, the same one the sidebar mark carries.
    private func bubble(_ diameter: CGFloat) -> some View {
        Circle()
            .fill(LinearGradient(colors: [BupsyMark.pink, BupsyMark.violet],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().fill(.white.opacity(0.8)).frame(width: diameter * 0.28)
                .offset(x: -diameter * 0.18, y: -diameter * 0.18))
            .frame(width: diameter, height: diameter)
    }
}
