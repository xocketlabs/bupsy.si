import BupsyKit
import SwiftUI

/// What a bot is doing, as a face can express it.
enum BotMood: Equatable {
    case idle
    case working
    case waitingForYou
    case failed
}

/// A playful, plush little creature for each bot.
///
/// Rebuilt after the first version read as a generic smiley: one circle with a corner squared off,
/// two eyes and a grin, so at 34pt in a list every bot looked like the same emoji in a different
/// colour. This follows libraries.dev's bot-avatars design language instead — distinct shapes,
/// glossy bead eyes and **no mouth**, with mood carried by motion rather than by an expression.
/// The design is theirs (MIT) and credited in NOTICE; the code is ours, written from the design,
/// not from their source.
///
/// - Shape and colour come from the bot's hue, which is derived from its name, so a bot keeps the
///   same face forever without anything being stored.
/// - Moods are things it *does*: idle glances around and occasionally hops; working bounces and
///   squints with delight; waiting-for-you looks straight at you and wiggles; failed closes its
///   eyes and droops.
///
/// Still drawn in one `Canvas` under one `TimelineView` per face, so twenty bots cost twenty cheap
/// draws a frame rather than twenty layer trees.
struct BotFace: View {
    let hue: Double
    let mood: BotMood
    var size: CGFloat = 26
    /// A face someone picked. nil derives it from the hue, as every face did before.
    var chosenShape: BotShape?
    var chosenColour: Int?

    /// The face a bot actually wears — its chosen one if it has one.
    init(bot: Bot, mood: BotMood, size: CGFloat = 26) {
        self.hue = bot.avatarHue
        self.mood = mood
        self.size = size
        self.chosenShape = bot.avatarShape
        self.chosenColour = bot.avatarColour
    }

    init(hue: Double, mood: BotMood, size: CGFloat = 26,
         shape: BotShape? = nil, colour: Int? = nil) {
        self.hue = hue
        self.mood = mood
        self.size = size
        self.chosenShape = shape
        self.chosenColour = colour
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { context, canvas in
                draw(in: &context, size: canvas,
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

    // MARK: - Identity

    /// 0...359, from the hue. Everything about the face is derived from this one number.
    ///
    /// The static helpers below are `nonisolated`: they are pure arithmetic, and `Bot` — a plain
    /// data struct, used off the main actor — calls them to know which face a bot wears. A
    /// `View`'s statics are main-actor isolated on the CI toolchain, which a newer local compiler
    /// did not enforce, so this compiled here and failed there.
    private var seed: Int { Self.seed(forHue: hue) }

    nonisolated static func seed(forHue hue: Double) -> Int { Int((hue * 360).rounded()) % 360 }

    /// Which of the fourteen shapes a hue produces — used to keep a roster varied.
    nonisolated static func shapeIndex(forHue hue: Double) -> Int {
        mix(seed(forHue: hue), salt: 1) % BotShape.allCases.count
    }

    /// Shape and colour each come from their own hash of the seed.
    ///
    /// The first version used `(seed × 7 + 3) % 14`, and 7 shares a factor with 14, so it could
    /// only ever produce two of the fourteen shapes. Any linear map would also have tied colour to
    /// shape, so every pick wore the same colour. Two independent hashes give every combination.
    private var shape: BotShape { chosenShape ?? Self.derivedShape(forHue: hue) }
    private var colour: Color { Self.colour(for: hue, chosen: chosenColour) }

    /// A bot's own colour — for its name and its mentions, so a bot reads as the same character
    /// in text as it does in its face.
    static func colour(of bot: Bot) -> Color { colour(for: bot.avatarHue, chosen: bot.avatarColour) }

    private static func colour(for hue: Double, chosen: Int?) -> Color {
        BotShape.palette[(chosen ?? derivedColour(forHue: hue)) % BotShape.palette.count]
    }

    nonisolated static func derivedShape(forHue hue: Double) -> BotShape {
        BotShape.allCases[mix(seed(forHue: hue), salt: 1) % BotShape.allCases.count]
    }

    nonisolated static func derivedColour(forHue hue: Double) -> Int {
        mix(seed(forHue: hue), salt: 2) % BotShape.palette.count
    }

    /// A small integer hash (murmur-style finaliser). Deterministic, so a face never changes.
    nonisolated static func mix(_ value: Int, salt: UInt32) -> Int {
        var h = UInt32(truncatingIfNeeded: value) &* 0x9E37_79B1 ^ salt &* 0x85EB_CA6B
        h ^= h >> 16
        h = h &* 0x7FEB_352D
        h ^= h >> 15
        h = h &* 0x846C_A68B
        h ^= h >> 16
        return Int(h)
    }

    /// A fraction unique to this bot, so two bots side by side never blink or hop in lockstep —
    /// which reads as mechanical rather than alive.
    private var phase: Double { Double((seed * 37) % 100) / 100 }

    // MARK: - Drawing

    func draw(in context: inout GraphicsContext, size canvas: CGSize, time: TimeInterval) {
        let unit = min(canvas.width, canvas.height)
        let motion = Motion(mood: mood, time: time, phase: phase)

        // Room for a hop and a stretch without clipping at the edge of the canvas.
        let body = CGRect(x: unit * 0.08, y: unit * 0.12, width: unit * 0.84, height: unit * 0.84)
        let base = CGPoint(x: body.midX, y: body.maxY)

        context.translateBy(x: base.x, y: base.y - motion.lift * unit)
        context.rotate(by: .degrees(motion.tilt))
        context.scaleBy(x: motion.scaleX, y: motion.scaleY)
        context.translateBy(x: -base.x, y: -base.y)

        let outline = shape.path(in: body)

        // Plush shading: a flat colour lit from the top left, falling off to the bottom right.
        context.fill(outline, with: .color(colour))
        context.drawLayer { layer in
            layer.clip(to: outline)
            layer.fill(outline, with: .radialGradient(
                Gradient(colors: [.white.opacity(0.42), .white.opacity(0)]),
                center: CGPoint(x: body.minX + body.width * 0.3, y: body.minY + body.height * 0.22),
                startRadius: 0, endRadius: body.width * 0.62))
            layer.fill(outline, with: .radialGradient(
                Gradient(colors: [.black.opacity(0), .black.opacity(0.22)]),
                center: CGPoint(x: body.minX + body.width * 0.38, y: body.minY + body.height * 0.3),
                startRadius: body.width * 0.35, endRadius: body.width * 0.85))
            if mood == .failed {
                layer.fill(outline, with: .color(.black.opacity(0.18)))
            }
        }

        drawEyes(in: &context, body: body, unit: unit, motion: motion)
    }

    private func drawEyes(in context: inout GraphicsContext, body: CGRect, unit: CGFloat,
                          motion: Motion) {
        let anchor = shape.eyeAnchor
        let centre = CGPoint(x: body.minX + body.width * anchor.x + motion.lookX * unit * 0.05,
                             y: body.minY + body.height * anchor.y + motion.lookY * unit * 0.035)
        let gap = unit * 0.105 * shape.eyeSpread
        let width = unit * 0.092 * motion.eyeScale
        let height = unit * 0.16 * motion.eyeScale
        let ink = Color(red: 0.08, green: 0.08, blue: 0.11)

        for side in [-1.0, 1.0] {
            let eye = CGPoint(x: centre.x + gap * side, y: centre.y)

            switch motion.eyes {
            case .open(let openness):
                let rect = CGRect(x: eye.x - width / 2, y: eye.y - height * openness / 2,
                                  width: width, height: max(height * openness, unit * 0.012))
                context.fill(Ellipse().path(in: rect), with: .color(ink))
                // The gloss is what makes them beads rather than dots. Skipped mid-blink, when
                // there is no eye to shine.
                if openness > 0.5 {
                    let shine = max(unit * 0.034, 1.2)
                    context.fill(Circle().path(in: CGRect(
                        x: eye.x - width * 0.18 - shine / 2, y: eye.y - height * 0.22 - shine / 2,
                        width: shine, height: shine)), with: .color(.white.opacity(0.9)))
                }

            case .happy, .closed:
                // ^ ^ for delight, ‿ ‿ for asleep: the same short arc, flipped.
                let up = { if case .happy = motion.eyes { return true } else { return false } }()
                var arc = Path()
                arc.move(to: CGPoint(x: eye.x - width * 0.58, y: eye.y + (up ? height * 0.12 : -height * 0.05)))
                arc.addQuadCurve(
                    to: CGPoint(x: eye.x + width * 0.58, y: eye.y + (up ? height * 0.12 : -height * 0.05)),
                    control: CGPoint(x: eye.x, y: eye.y + (up ? -height * 0.4 : height * 0.32)))
                context.stroke(arc, with: .color(ink),
                               style: StrokeStyle(lineWidth: max(unit * 0.035, 1), lineCap: .round))
            }
        }
    }
}

// MARK: - Motion

/// Everything about a frame that depends on mood and time, worked out once per draw.
private struct Motion {
    enum Eyes { case open(CGFloat), happy, closed }

    var lift: CGFloat = 0
    var tilt: Double = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0
    var eyeScale: CGFloat = 1
    var eyes: Eyes = .open(1)

    init(mood: BotMood, time: TimeInterval, phase: Double) {
        let t = time + phase * 10

        switch mood {
        case .idle:
            // Glance, hold, glance — not a slow wander, which reads as a screensaver.
            (lookX, lookY) = Self.glance(t, every: 2.8)
            breathe(t, depth: 0.018)
            hop(t, every: 5.5 + phase * 3, height: 0.07, duration: 0.5)
            eyes = .open(Self.blink(t, every: 3.4 + phase * 2.4))

        case .working:
            // Busy: a steady bounce and a little sway, eyes forward. Every few seconds it
            // squints with delight, which is the difference between "working" and "panicking".
            hop(t, every: 0.62, height: 0.085, duration: 0.62)
            tilt = sin(t * 4.1) * 5
            lookY = -0.3
            let laughing = (t.truncatingRemainder(dividingBy: 4.2)) < 0.7
            eyes = laughing ? .happy : .open(Self.blink(t, every: 2.6))

        case .waitingForYou:
            // Looks straight at you, eyes a touch wider, and wiggles in short bursts — the
            // gesture of something trying to get your attention without shouting.
            let burst = t.truncatingRemainder(dividingBy: 1.8)
            tilt = burst < 0.6 ? sin(burst * .pi * 5) * 7 : 0
            breathe(t, depth: 0.02)
            eyeScale = 1.15
            eyes = .open(Self.blink(t, every: 4.5))

        case .failed:
            // Asleep rather than broken: eyes shut, slumped, breathing slowly.
            scaleY = 0.95 + 0.012 * CGFloat(sin(t * 1.3))
            scaleX = 1.03
            lookY = 0.4
            eyes = .closed
        }
    }

    private mutating func breathe(_ t: Double, depth: CGFloat) {
        scaleY *= 1 + depth * CGFloat(sin(t * 2))
        scaleX *= 1 - depth * 0.5 * CGFloat(sin(t * 2))
    }

    /// A hop with stretch on the way up and a squash on landing.
    private mutating func hop(_ t: Double, every period: Double, height: CGFloat, duration: Double) {
        let local = t.truncatingRemainder(dividingBy: period)
        guard local < duration else { return }
        let p = local / duration
        let arc = CGFloat(sin(p * .pi))
        lift = height * arc
        scaleY *= 1 + 0.07 * arc
        scaleX *= 1 - 0.05 * arc
        // Squash on the ground at either end of the jump.
        let ground = CGFloat(max(0, 1 - arc * 4))
        scaleY *= 1 - 0.06 * ground
        scaleX *= 1 + 0.05 * ground
    }

    /// 0...1 openness: fully open except for a quick blink once per period.
    private static func blink(_ t: Double, every period: Double) -> CGFloat {
        let local = t.truncatingRemainder(dividingBy: period)
        guard local < 0.16 else { return 1 }
        return CGFloat(abs(cos(local / 0.16 * .pi)))
    }

    /// Picks a new direction every `period` seconds and moves there quickly, then holds.
    private static func glance(_ t: Double, every period: Double) -> (CGFloat, CGFloat) {
        let slot = Int((t / period).rounded(.down))
        let into = t - Double(slot) * period
        let ease = CGFloat(min(1, into / 0.22))
        let from = target(slot - 1), to = target(slot)
        return (from.0 + (to.0 - from.0) * ease, from.1 + (to.1 - from.1) * ease)
    }

    /// Mostly looking near the middle, sometimes off to a side — a creature, not a searchlight.
    private static func target(_ n: Int) -> (CGFloat, CGFloat) {
        func noise(_ k: Int) -> Double {
            let x = sin(Double(k) * 12.9898 + 78.233) * 43758.5453
            return x - x.rounded(.down)
        }
        let x = noise(n) * 2 - 1, y = noise(n * 7 + 13) * 2 - 1
        return (CGFloat(x * 0.9), CGFloat(y * 0.6))
    }
}

// MARK: - Shapes

/// Fourteen silhouettes, so a roster reads as a crowd of characters rather than one face
/// recoloured. All closed paths in a unit square scaled to the body rect; the polygonal ones are
/// softened by unioning them with their own round-jointed stroke, which is what makes a triangle
/// read as plush rather than sharp.
/// Small still faces for inline mentions, rendered once per look and reused.
///
/// `Text` cannot hold a view, only an image, so a mention's face is drawn to an image the first
/// time it is needed. Keyed by everything that changes the face, so a new pick redraws it.
@MainActor
enum MentionFaces {
    private static var cache: [String: NSImage] = [:]

    static func image(for bot: Bot, size: CGFloat) -> NSImage? {
        let shape = bot.avatarShape ?? BotFace.derivedShape(forHue: bot.avatarHue)
        let colour = bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue)
        let key = "\(shape.rawValue)-\(colour)-\(size)"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: StillBotFace(shape: shape, colour: colour, size: size))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        cache[key] = image
        return image
    }
}

/// A face held still at one moment — for the app icon and other one-off renders, where a
/// `TimelineView` has no timeline to run on.
struct StillBotFace: View {
    let shape: BotShape
    let colour: Int
    var size: CGFloat
    var at: TimeInterval = 0.4

    var body: some View {
        let face = BotFace(hue: 0.5, mood: .idle, size: size, shape: shape, colour: colour)
        Canvas { context, canvas in face.draw(in: &context, size: canvas, time: at) }
            .frame(width: size, height: size)
    }
}

enum BotShape: String, CaseIterable, Sendable {
    case circle, drop, pick, triangle, squircle, pill, pebble, ghost, cat, cloud, flower, clover,
         star, hexagon

    /// A word for the picker. Plain, because these are characters, not geometry.
    var label: String { rawValue.capitalized }

    /// Saturated and friendly, with one white — the palette Grok Bot's roster lands on. Chosen
    /// colours rather than raw hues, because a raw hue wheel spends a third of itself on
    /// muddy yellow-greens.
    static let palette: [Color] = [
        rgb(61, 170, 92), rgb(226, 70, 139), rgb(59, 123, 224), rgb(47, 167, 154),
        rgb(160, 104, 62), rgb(242, 144, 58), rgb(242, 194, 48), rgb(224, 69, 69),
        rgb(138, 85, 224), rgb(240, 111, 85), rgb(92, 201, 160), rgb(75, 179, 230),
        rgb(176, 123, 232), rgb(238, 236, 230),
    ]

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// Where the face sits, as a fraction of the body. A triangle's visual centre is low; a
    /// pointing shape's is away from its point.
    var eyeAnchor: CGPoint {
        switch self {
        case .drop: CGPoint(x: 0.56, y: 0.56)
        case .pick: CGPoint(x: 0.4, y: 0.5)
        case .triangle: CGPoint(x: 0.5, y: 0.64)
        case .ghost: CGPoint(x: 0.5, y: 0.44)
        case .cat, .cloud: CGPoint(x: 0.5, y: 0.6)
        case .star: CGPoint(x: 0.5, y: 0.54)
        default: CGPoint(x: 0.5, y: 0.47)
        }
    }

    /// Narrow shapes need their eyes closer together to stay inside the body.
    var eyeSpread: CGFloat {
        switch self {
        case .triangle, .star: 0.8
        case .pill: 1.15
        default: 1
        }
    }

    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
            Circle().path(in: CGRect(x: r.minX + r.width * (x - radius),
                                     y: r.minY + r.height * (y - radius),
                                     width: r.width * radius * 2, height: r.height * radius * 2))
        }
        func soft(_ points: [CGPoint], rounding: CGFloat) -> Path {
            var polygon = Path()
            polygon.addLines(points)
            polygon.closeSubpath()
            return polygon.union(polygon.strokedPath(StrokeStyle(
                lineWidth: r.width * rounding, lineCap: .round, lineJoin: .round)))
        }
        func union(_ parts: [Path]) -> Path {
            parts.dropFirst().reduce(parts[0]) { $0.union($1) }
        }

        switch self {
        case .circle:
            return Ellipse().path(in: r)

        case .drop:
            // A teardrop pointing up and to the left — the shape Grok Bot's roster leans on most.
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: r.width * 0.08, bottomLeading: r.width * 0.5,
                bottomTrailing: r.width * 0.5, topTrailing: r.width * 0.5))
                .path(in: r)

        case .pick:
            return soft([p(0.12, 0.14), p(0.9, 0.5), p(0.12, 0.86)], rounding: 0.3)

        case .triangle:
            return soft([p(0.5, 0.12), p(0.88, 0.86), p(0.12, 0.86)], rounding: 0.3)

        case .squircle:
            return RoundedRectangle(cornerRadius: r.width * 0.34, style: .continuous).path(in: r)

        case .pill:
            return Capsule().path(in: CGRect(x: r.minX, y: r.minY + r.height * 0.16,
                                             width: r.width, height: r.height * 0.72))

        case .pebble:
            // A tall egg leaning to one side. It was a wide ellipse, which next to the pill was
            // the same shape twice — indistinguishable at sidebar size.
            let egg = Ellipse().path(in: CGRect(x: r.minX + r.width * 0.12, y: r.minY,
                                                width: r.width * 0.76, height: r.height))
            return egg.applying(CGAffineTransform(translationX: r.midX, y: r.midY)
                .rotated(by: -0.26)
                .translatedBy(x: -r.midX, y: -r.midY))

        case .ghost:
            var path = Path()
            path.move(to: p(0.1, 0.5))
            path.addArc(center: p(0.5, 0.5), radius: r.width * 0.4,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: p(0.9, 0.86))
            // Three soft scallops along the hem, each bulging downward.
            let stops: [CGFloat] = [0.9, 0.633, 0.367, 0.1]
            for (from, to) in zip(stops, stops.dropFirst()) {
                path.addQuadCurve(to: p(to, 0.86), control: p((from + to) / 2, 0.99))
            }
            path.closeSubpath()
            return path

        case .cat:
            return union([
                circle(0.5, 0.58, 0.38),
                soft([p(0.16, 0.42), p(0.22, 0.1), p(0.44, 0.26)], rounding: 0.12),
                soft([p(0.84, 0.42), p(0.78, 0.1), p(0.56, 0.26)], rounding: 0.12),
            ])

        case .cloud:
            return union([
                circle(0.3, 0.6, 0.24), circle(0.52, 0.44, 0.3), circle(0.74, 0.6, 0.23),
                RoundedRectangle(cornerRadius: r.width * 0.16).path(in: CGRect(
                    x: r.minX + r.width * 0.08, y: r.minY + r.height * 0.56,
                    width: r.width * 0.84, height: r.height * 0.3)),
            ])

        case .flower:
            var petals: [Path] = [circle(0.5, 0.5, 0.3)]
            for index in 0..<6 {
                let angle = Double(index) / 6 * 2 * .pi
                petals.append(circle(0.5 + 0.28 * cos(angle), 0.5 + 0.28 * sin(angle), 0.2))
            }
            return union(petals)

        case .clover:
            return union([
                circle(0.5, 0.29, 0.24), circle(0.71, 0.5, 0.24), circle(0.5, 0.71, 0.24),
                circle(0.29, 0.5, 0.24), circle(0.5, 0.5, 0.24),
            ])

        case .star:
            var points: [CGPoint] = []
            for index in 0..<10 {
                let radius: CGFloat = index.isMultiple(of: 2) ? 0.42 : 0.24
                let angle = Double(index) / 10 * 2 * .pi - .pi / 2
                points.append(p(0.5 + radius * CGFloat(cos(angle)),
                                0.54 + radius * CGFloat(sin(angle))))
            }
            return soft(points, rounding: 0.16)

        case .hexagon:
            var points: [CGPoint] = []
            for index in 0..<6 {
                let angle = Double(index) / 6 * 2 * .pi
                points.append(p(0.5 + 0.4 * CGFloat(cos(angle)), 0.5 + 0.4 * CGFloat(sin(angle))))
            }
            return soft(points, rounding: 0.18)
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
/// A calm, breathing glow around the composer while a bot works.
///
/// It replaced a bright streak that orbited the border. On a wide, short box an angular sweep
/// races round the corners and crawls along the long edges, and it took the bot's own hue, so on
/// some bots it read as an orange flicker against a pink app. This pulses evenly all the way round,
/// in the app's accent, with a soft halo — "working" without being looked at.
struct BorderBeam: ViewModifier {
    @Environment(\.palette) private var palette
    var hue: Double = 0.58
    var cornerRadius: CGFloat = 10
    var period: Double = 2.4

    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                // 0…1…0, eased, so it lingers at the ends of the breath.
                let breath = 0.5 - 0.5 * cos(phase * 2 * .pi)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(palette.primary.opacity(0.35 + 0.45 * breath), lineWidth: 1.5)
                    .shadow(color: palette.primary.opacity(0.18 + 0.27 * breath), radius: 4 + 6 * breath)
            }
            .allowsHitTesting(false)
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
