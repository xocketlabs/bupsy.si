import BupsyKit
import SwiftUI

/// What a bot is doing, as a face can express it.
enum BotMood: Equatable {
    case idle
    case working
    case waitingForYou
    case failed

    var ringColor: Color? {
        switch self {
        case .idle: nil
        case .working: .green
        case .waitingForYou: .orange
        case .failed: .red
        }
    }
}

/// An animated face for a bot.
///
/// The roster is the home screen and these are the first thing anyone sees, so they do real work:
/// a glance should say which bot is busy, which is stuck waiting on you, and which has failed —
/// without reading a word.
///
/// Drawn in `Canvas` under a single `TimelineView`, so one timeline drives every face on screen
/// rather than each one owning a timer. A roster of twenty bots animating independently is how a
/// menu-bar app earns a reputation for draining batteries.
///
/// Reimplemented in SwiftUI rather than ported: libraries.dev's bot-avatars is React-only, and
/// its Swift sibling BorderBeamKit sits in a monorepo subdirectory that SPM cannot depend on
/// remotely. The design language is theirs (MIT) and credited in NOTICE; the code is ours.
struct BotFace: View {
    let hue: Double
    let mood: BotMood
    var size: CGFloat = 26

    /// Which silhouette this bot wears, 0...3.
    ///
    /// Hue alone was not enough to tell bots apart. In a list of two-line rows the avatar is about
    /// 34pt, every face has the same two eyes and the same smile, and two bots a few degrees apart
    /// on the colour wheel are indistinguishable at a glance — which defeats the point of having a
    /// face at all. Varying the outline gives a second, stronger signal that survives being small.
    ///
    /// Derived from the hue rather than stored, so it is stable for a given name and costs no
    /// schema. Multiplied by a prime first so that form and hue do not move together — otherwise
    /// every yellow bot would also be the same shape.
    private var form: Int {
        Int((hue * 97).truncatingRemainder(dividingBy: 4))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize,
                     time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch mood {
        case .idle: "idle"
        case .working: "working"
        case .waitingForYou: "waiting for you"
        case .failed: "something went wrong"
        }
    }

    /// A circle with one corner pulled square — the same silhouette at four rotations.
    ///
    /// Four variants of one shape rather than four different shapes: the bots still look like a
    /// family, which is the whole point of them having a shared face. `UnevenRoundedRectangle`
    /// does the work, so there is no hand-rolled path arithmetic to get subtly wrong at small
    /// sizes.
    static func bodyPath(in rect: CGRect, form: Int) -> Path {
        let round = min(rect.width, rect.height) / 2
        let corner = round * 0.3
        let radii: RectangleCornerRadii = switch form {
        case 0: .init(topLeading: round, bottomLeading: corner,
                      bottomTrailing: round, topTrailing: round)
        case 1: .init(topLeading: corner, bottomLeading: round,
                      bottomTrailing: round, topTrailing: round)
        case 2: .init(topLeading: round, bottomLeading: round,
                      bottomTrailing: corner, topTrailing: round)
        default: .init(topLeading: round, bottomLeading: round,
                       bottomTrailing: round, topTrailing: corner)
        }
        return UnevenRoundedRectangle(cornerRadii: radii).path(in: rect)
    }

    private func draw(in context: inout GraphicsContext, size canvas: CGSize, time: TimeInterval) {
        let rect = CGRect(origin: .zero, size: canvas)
        let unit = canvas.width / 26

        // Body. Two stops of the same hue so a bot reads as one colour at a glance but still
        // has some depth up close.
        context.fill(
            Self.bodyPath(in: rect, form: form),
            with: .linearGradient(
                Gradient(colors: [
                    Color(hue: hue, saturation: 0.46 + Double(form) * 0.06, brightness: 0.97),
                    Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1),
                          saturation: 0.74, brightness: 0.74),
                ]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        )

        // A blink is a quick dip in eye height on a loop whose period is derived from the hue,
        // so two bots side by side do not blink in lockstep — which reads as mechanical rather
        // than alive.
        let blinkPeriod = 3.4 + hue * 2.6
        let blinkPhase = (time.truncatingRemainder(dividingBy: blinkPeriod)) / blinkPeriod
        let blinking = blinkPhase > 0.965
        let eyeOpen: CGFloat = blinking ? 0.12 : 1

        // Working bots scan side to side; idle bots drift slowly. Both are small — a face that
        // moves a lot is distracting in a sidebar you keep open all day.
        let sway: CGFloat
        switch mood {
        case .working: sway = CGFloat(sin(time * 3.2)) * unit * 1.5
        case .idle: sway = CGFloat(sin(time * 0.5)) * unit * 0.5
        case .waitingForYou, .failed: sway = 0
        }

        // Proportions are deliberately bold. A roster avatar is 26pt, so features drawn at a
        // "realistic" scale come out two points wide and read as a plain gradient circle at a
        // glance — which is exactly what the first version did. Big eyes are legible small.
        let eyeY = rect.midY - unit * 1.5
        let eyeSpacing = unit * 9.5
        let eyeWidth = unit * 5.2
        let eyeHeight = unit * 6.4 * eyeOpen

        for direction in [-1.0, 1.0] {
            let centre = CGPoint(x: rect.midX + CGFloat(direction) * eyeSpacing / 2 + sway, y: eyeY)
            let eye = CGRect(
                x: centre.x - eyeWidth / 2, y: centre.y - eyeHeight / 2,
                width: eyeWidth, height: max(eyeHeight, unit * 0.9))
            context.fill(Capsule().path(in: eye), with: .color(.black.opacity(0.82)))

            // A highlight turns two dark blobs into eyes.
            if !blinking {
                let shine = CGRect(
                    x: eye.minX + eyeWidth * 0.26, y: eye.minY + eyeHeight * 0.16,
                    width: eyeWidth * 0.3, height: eyeHeight * 0.26)
                context.fill(Circle().path(in: shine), with: .color(.white.opacity(0.85)))
            }
        }

        drawMouth(in: &context, rect: rect, unit: unit, time: time, sway: sway)

        if let ring = mood.ringColor {
            // Pulsed only while working. A static dot for "needs you" is easier to notice in
            // peripheral vision than another thing moving.
            let alpha = mood == .working ? 0.55 + 0.45 * abs(sin(time * 2.4)) : 1
            // Follows the body's outline rather than being a circle around a squared-off corner,
            // which looked like the ring belonged to a different avatar.
            context.stroke(
                Self.bodyPath(in: rect.insetBy(dx: -unit * 1.1, dy: -unit * 1.1), form: form),
                with: .color(ring.opacity(alpha)),
                lineWidth: unit * 0.85)
        }
    }

    private func drawMouth(
        in context: inout GraphicsContext, rect: CGRect,
        unit: CGFloat, time: TimeInterval, sway: CGFloat
    ) {
        let centre = CGPoint(x: rect.midX + sway * 0.4, y: rect.midY + unit * 6.2)
        var path = Path()

        switch mood {
        case .idle:
            path.move(to: CGPoint(x: centre.x - unit * 3.0, y: centre.y))
            path.addQuadCurve(
                to: CGPoint(x: centre.x + unit * 3.0, y: centre.y),
                control: CGPoint(x: centre.x, y: centre.y + unit * 3.0))

        case .working:
            // An open mouth that breathes, so "busy" reads without relying on colour — which
            // matters for anyone who cannot distinguish the green ring from the orange one.
            let openness = unit * (1.8 + 1.4 * abs(sin(time * 3.0)))
            path.addEllipse(in: CGRect(
                x: centre.x - unit * 2.2, y: centre.y - openness / 2,
                width: unit * 4.4, height: openness))

        case .waitingForYou:
            path.move(to: CGPoint(x: centre.x - unit * 2.6, y: centre.y))
            path.addLine(to: CGPoint(x: centre.x + unit * 2.6, y: centre.y))

        case .failed:
            path.move(to: CGPoint(x: centre.x - unit * 2.6, y: centre.y + unit * 1.4))
            path.addQuadCurve(
                to: CGPoint(x: centre.x + unit * 2.6, y: centre.y + unit * 1.4),
                control: CGPoint(x: centre.x, y: centre.y - unit * 1.6))
        }

        if case .working = mood {
            context.fill(path, with: .color(.black.opacity(0.7)))
        } else {
            context.stroke(
                path,
                with: .color(.black.opacity(0.7)),
                style: StrokeStyle(lineWidth: unit * 1.5, lineCap: .round))
        }
    }
}

/// Dotted orbs for "thinking", the most-seen animation in the app — runs last minutes, not
/// moments. Kept small and quiet for that reason.
struct ThinkingOrbs: View {
    var hue: Double = 0.58
    var dotSize: CGFloat = 5
    var count: Int = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: dotSize * 0.6) {
                ForEach(0..<count, id: \.self) { index in
                    let phase = time * 2.2 - Double(index) * 0.55
                    let lift = CGFloat(sin(phase)) * dotSize * 0.42
                    Circle()
                        .fill(Color(hue: hue, saturation: 0.45, brightness: 0.95))
                        .frame(width: dotSize, height: dotSize)
                        .opacity(0.35 + 0.65 * (0.5 + 0.5 * sin(phase)))
                        .offset(y: -lift)
                }
            }
        }
        .frame(height: dotSize * 2)
        .accessibilityLabel("Thinking")
    }
}

/// A light that travels the border of whatever it is applied to.
///
/// Used on the composer while a bot is replying: it says "live" without a spinner competing for
/// attention with the text arriving above it.
struct BorderBeam: ViewModifier {
    var hue: Double = 0.58
    var cornerRadius: CGFloat = 10
    var lineWidth: CGFloat = 1.5
    var period: Double = 2.6

    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let progress = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: Color(hue: hue, saturation: 0.55, brightness: 1),
                                      location: 0.06),
                                .init(color: .clear, location: 0.16),
                                .init(color: .clear, location: 1),
                            ],
                            center: .center,
                            angle: .degrees(progress * 360)
                        ),
                        lineWidth: lineWidth)
            }
        }
    }
}

extension View {
    /// Applies the beam only while active, so an idle composer costs no animation frames —
    /// a `TimelineView` that is never on screen is still a `TimelineView`.
    @ViewBuilder
    func borderBeam(hue: Double, active: Bool, cornerRadius: CGFloat = 10) -> some View {
        if active {
            modifier(BorderBeam(hue: hue, cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}
