import BupsyKit
import SwiftUI

/// What a bot is doing, as a face can express it.
enum BotMood: Equatable {
    case idle
    case working
    case waitingForYou
    /// Just finished something: a hop and a grin. Short-lived by nature.
    case done
    /// Paused, or nothing scheduled for a while. Antenna droops, z's drift up.
    case sleeping
    case failed
}

/// Bupsy: a gummy little creature with a status light on an antenna.
///
/// Ported from the Bupsy design system's `Mascot` so the app and the designs are the same
/// character, drawn from the same 120-unit geometry. The antenna light is the status: violet when
/// idle, green while working or done, a white flash when it needs you, grey asleep, red on error.
/// The face carries the rest: eyes, brows and mouth all change with the mood, and each mood has
/// its own small motion (breathing, bobbing, a wiggle and wave, a hop, a snore, a dizzy wobble).
///
/// - Shape and colour are the bot's own picks. A bot that never picked wears the plain Bup shape
///   in a colour derived from its name, so it still has a stable face without storing anything.
/// - Still drawn in one `Canvas` under one `TimelineView`, so a long roster stays cheap.
/// - Reduce Motion freezes every face on a single calm frame.
struct BotFace: View {
    let hue: Double
    let mood: BotMood
    var size: CGFloat = 26
    /// A face someone picked. nil falls back to the default shape.
    var chosenShape: BotShape?
    var chosenColour: Int?
    /// One frame, no timeline. For faces that are on screen but not the point: an idle bot in a
    /// list costs nothing this way, where 30 frames a second each adds up across a roster.
    var still = false
    /// Set where the face is drawn outside the view tree (an image render), whose environment
    /// would otherwise always read as light.
    var scheme: ColorScheme?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The face a bot actually wears, its chosen one if it has one.
    init(bot: Bot, mood: BotMood, size: CGFloat = 26, still: Bool = false) {
        self.hue = bot.avatarHue
        self.mood = mood
        self.size = size
        self.chosenShape = bot.avatarShape
        self.chosenColour = bot.avatarColour
        self.still = still
    }

    init(hue: Double, mood: BotMood, size: CGFloat = 26,
         shape: BotShape? = nil, colour: Int? = nil, still: Bool = false) {
        self.hue = hue
        self.mood = mood
        self.size = size
        self.chosenShape = shape
        self.chosenColour = colour
        self.still = still
    }

    /// Whether a face in this mood moves at all. A resting bot holds still: each moving face
    /// updates the window every frame, and each update walks the whole view tree, the open
    /// chat's messages included, which kept an idle app at a quarter of a core even at 12 frames
    /// a second. Measured on a real roster. Motion is kept for what is worth noticing: working,
    /// waiting on you, done, failed.
    static func moves(in mood: BotMood) -> Bool {
        switch mood {
        case .idle, .sleeping: false
        default: true
        }
    }

    var body: some View {
        Group {
            if reduceMotion || still || !Self.moves(in: mood) {
                Canvas { context, canvas in draw(in: &context, size: canvas, time: 0.4) }
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    Canvas { context, canvas in
                        draw(in: &context, size: canvas,
                             time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch mood {
        case .idle: "idle"
        case .working: "working"
        case .waitingForYou: "waiting for you"
        case .done: "done"
        case .sleeping: "asleep"
        case .failed: "something went wrong"
        }
    }

    // MARK: - Identity

    /// The static helpers below are `nonisolated`: they are pure arithmetic, and `Bot`, a plain
    /// data struct used off the main actor, calls them to know which face a bot wears.
    private var seed: Int { Self.seed(forHue: hue) }

    nonisolated static func seed(forHue hue: Double) -> Int { Int((hue * 360).rounded()) % 360 }

    /// Which shape a hue would suggest. Only used to vary hues; a bot without a pick wears Bup.
    nonisolated static func shapeIndex(forHue hue: Double) -> Int {
        mix(seed(forHue: hue), salt: 1) % BotShape.allCases.count
    }

    private var shape: BotShape { chosenShape ?? Self.derivedShape(forHue: hue) }

    /// A bot's own colour, for its name and its mentions, so a bot reads as the same character in
    /// text as it does in its face.
    static func colour(of bot: Bot) -> Color { colour(for: bot.avatarHue, chosen: bot.avatarColour) }

    private static func colour(for hue: Double, chosen: Int?) -> Color {
        BotShape.palette[(chosen ?? derivedColour(forHue: hue)) % BotShape.palette.count]
    }

    /// Every bot that has not picked a shape wears the plain one. Faces picked under the old set
    /// of shapes no longer decode, so they land here too, and their owners can pick again.
    nonisolated static func derivedShape(forHue hue: Double) -> BotShape { .bup }

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

    /// A fraction unique to this bot, so two bots side by side never blink or hop in lockstep.
    private var phase: Double { Double((seed * 37) % 100) / 100 }

    // MARK: - Drawing

    func draw(in context: inout GraphicsContext, size canvas: CGSize, time: TimeInterval) {
        let unit = min(canvas.width, canvas.height)
        let scale = unit / 120
        context.translateBy(x: (canvas.width - unit) / 2, y: (canvas.height - unit) / 2)
        context.scaleBy(x: scale, y: scale)

        let tint = BotShape.rgbPalette[(chosenColour ?? Self.derivedColour(forHue: hue))
                                       % BotShape.rgbPalette.count]
        let ink = MascotInk(body: tint, dark: (scheme ?? colorScheme) == .dark)
        let motion = MascotMotion(mood: mood, time: time + phase * 10)
        // Under 56pt the extras (sparks, z's, sweat, the ground shadow) turn to noise.
        let mini = unit < 56

        MascotDrawing(shape: shape, mood: mood, ink: ink, motion: motion, mini: mini,
                      pointsPerUnit: scale)
            .draw(in: &context)
    }
}

// MARK: - Colour

/// An sRGB triple, kept as numbers so the body's light and dark tones can be mixed from it.
struct MascotRGB: Sendable {
    let r: Double, g: Double, b: Double

    func mixed(with other: MascotRGB, _ amount: Double) -> MascotRGB {
        MascotRGB(r: r * amount + other.r * (1 - amount),
                  g: g * amount + other.g * (1 - amount),
                  b: b * amount + other.b * (1 - amount))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    static func hex(_ value: UInt32) -> MascotRGB {
        MascotRGB(r: Double((value >> 16) & 0xFF) / 255,
                  g: Double((value >> 8) & 0xFF) / 255,
                  b: Double(value & 0xFF) / 255)
    }
}

/// Every colour one face needs, worked out once per frame from the body colour.
private struct MascotInk {
    let body: Color
    let light: Color
    let dark: Color
    let mouth: Color
    let shadow: Color
    let muted: Color
    let success: Color
    let info = MascotRGB.hex(0x8C4BFF).color
    let destructive = MascotRGB.hex(0xE10B05).color
    let pupil = MascotRGB.hex(0x141414).color
    let tongue = MascotRGB.hex(0xFF8FAB).color
    let spark = MascotRGB.hex(0xF7B928).color
    let sweat = MascotRGB.hex(0x8FD3FF).color

    init(body tint: MascotRGB, dark isDark: Bool) {
        body = tint.color
        light = tint.mixed(with: .hex(0xFFFFFF), 0.62).color
        dark = tint.mixed(with: .hex(0x000000), 0.72).color
        mouth = tint.mixed(with: .hex(0x1A0612), 0.28).color
        shadow = (isDark ? Color.white : Color.black).opacity(0.1)
        muted = isDark ? MascotRGB.hex(0xA1A1A1).color : MascotRGB.hex(0x737373).color
        success = isDark ? MascotRGB.hex(0x33B75F).color : MascotRGB.hex(0x007C32).color
    }
}

// MARK: - Motion

/// Everything about a frame that depends on mood and time. Mirrors the design system's CSS
/// keyframes so a bot moves the same in the app as in the designs.
private struct MascotMotion {
    /// The whole figure, pivoting at its feet.
    var lift: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var tilt: Double = 0
    var shiftX: CGFloat = 0
    /// Eyes: 1 open, near 0 mid-blink.
    var blink: CGFloat = 1
    var dart: CGPoint = .zero
    var browLift: CGFloat = 0
    var wave: Double = 0
    var bulbOpacity: Double = 1
    var spin: Double = 0
    var orbit: Double = 0
    let time: Double

    init(mood: BotMood, time t: Double) {
        time = t
        switch mood {
        case .idle:
            breathe(t, period: 3.4)
            blink = Self.blink(t, period: 4.6)

        case .working:
            // bm-bob: .5s alternate, a squash at the bottom and a stretch at the top.
            let p = Self.alternate(t, period: 0.5)
            lift = 4 * p
            scaleX = 1.02 - 0.03 * p
            scaleY = 0.98 + 0.04 * p
            bulbOpacity = 1 - 0.65 * Self.alternate(t, period: 0.5)
            // bm-dart: eyes flick around in steps, like reading.
            let step = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
            dart = step < 0.3 ? .zero : step < 0.55 ? CGPoint(x: -6, y: 0)
                : step < 0.8 ? CGPoint(x: -2, y: -2) : CGPoint(x: 1, y: 1)

        case .waitingForYou:
            // bm-wiggle, a waving hand and a flashing light: trying to get your attention.
            tilt = Self.keyframes(t, period: 0.9, [(0, 0), (0.2, -5), (0.4, 4), (0.6, -3), (0.8, 2), (1, 0)])
            wave = -12 + 38 * Self.alternate(t, period: 0.45)
            browLift = -2.5 * CGFloat(sin(t / 0.9 * .pi * 2) * 0.5 + 0.5)
            bulbOpacity = Int(t / 0.35).isMultiple(of: 2) ? 1 : 0.35

        case .done:
            // bm-hop: up with a stretch, down with a squash.
            let p = t.truncatingRemainder(dividingBy: 1.1) / 1.1
            lift = 14 * CGFloat(Self.keyframes(p, period: 1, [(0, 0), (0.35, 1), (0.65, 0), (1, 0)]))
            scaleX = CGFloat(Self.keyframes(p, period: 1, [(0, 1.06), (0.35, 0.96), (0.65, 1.07), (0.8, 0.99), (1, 1.06)]))
            scaleY = CGFloat(Self.keyframes(p, period: 1, [(0, 0.92), (0.35, 1.05), (0.65, 0.91), (0.8, 1.02), (1, 0.92)]))

        case .sleeping:
            breathe(t, period: 4.2)

        case .failed:
            // bm-wobble, with spiral eyes and stars circling overhead.
            let p = t.truncatingRemainder(dividingBy: 1.6) / 1.6
            tilt = Self.keyframes(p, period: 1, [(0, 0), (0.25, -7), (0.5, 5), (0.75, -3), (1, 0)])
            shiftX = CGFloat(Self.keyframes(p, period: 1, [(0, 0), (0.25, -2), (0.5, 0), (0.75, 2), (1, 0)]))
            spin = (t.truncatingRemainder(dividingBy: 1.1) / 1.1) * 360
            orbit = (t.truncatingRemainder(dividingBy: 2.2) / 2.2) * 360
        }
    }

    private mutating func breathe(_ t: Double, period: Double) {
        let p = CGFloat(0.5 - 0.5 * cos(t / period * 2 * .pi))
        scaleX = 1 + 0.025 * p
        scaleY = 1 - 0.03 * p
    }

    /// 0 to 1 and back, eased, once per `period` each way.
    static func alternate(_ t: Double, period: Double) -> CGFloat {
        CGFloat(0.5 - 0.5 * cos(t / period * .pi))
    }

    /// bm-blink: open, then a quick squeeze shut near the end of each cycle.
    static func blink(_ t: Double, period: Double) -> CGFloat {
        let p = t.truncatingRemainder(dividingBy: period) / period
        if p < 0.9 { return 1 }
        if p < 0.93 { return CGFloat(1 - (p - 0.9) / 0.03 * 0.92) }
        if p < 0.96 { return CGFloat(0.08 + (p - 0.93) / 0.03 * 0.92) }
        return 1
    }

    /// Linear interpolation through (fraction, value) stops over one period.
    static func keyframes(_ t: Double, period: Double, _ stops: [(Double, Double)]) -> Double {
        let p = t.truncatingRemainder(dividingBy: period) / period
        for (a, b) in zip(stops, stops.dropFirst()) where p >= a.0 && p <= b.0 {
            let span = b.0 - a.0
            let k = span > 0 ? (p - a.0) / span : 0
            return a.1 + (b.1 - a.1) * k
        }
        return stops.last?.1 ?? 0
    }

    /// 0...1 progress of a looping animation with a start delay, as CSS animation-delay does.
    func progress(period: Double, delay: Double) -> Double {
        let local = (time - delay).truncatingRemainder(dividingBy: period)
        return (local < 0 ? local + period : local) / period
    }
}

// MARK: - Geometry

/// The drawing itself, in the design system's 120-unit box.
private struct MascotDrawing {
    let shape: BotShape
    let mood: BotMood
    let ink: MascotInk
    let motion: MascotMotion
    let mini: Bool
    /// On-screen points per drawing unit, so mini faces can keep thin parts visible.
    var pointsPerUnit: CGFloat = 1

    /// A width in drawing units that is never thinner than `minimum` points on screen. At
    /// sidebar size the design's widths come out under a point and the part disappears.
    private func atLeast(_ units: CGFloat, points minimum: CGFloat) -> CGFloat {
        guard mini, pointsPerUnit > 0 else { return units }
        return max(units, minimum / pointsPerUnit)
    }

    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .circular)
    }

    private func quad(_ from: CGPoint, _ control: CGPoint, _ to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        return path
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private func rotated(_ path: Path, _ degrees: Double, about c: CGPoint) -> Path {
        path.applying(CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -c.x, y: -c.y))
    }

    private func round(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    /// A four-point twinkle, the same curve the design system draws.
    private func star(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) -> Path {
        let k = s * 0.2
        var path = Path()
        path.move(to: pt(cx, cy - s))
        path.addQuadCurve(to: pt(cx + s, cy), control: pt(cx + k, cy - k))
        path.addQuadCurve(to: pt(cx, cy + s), control: pt(cx + k, cy + k))
        path.addQuadCurve(to: pt(cx - s, cy), control: pt(cx - k, cy + k))
        path.addQuadCurve(to: pt(cx, cy - s), control: pt(cx - k, cy - k))
        path.closeSubpath()
        return path
    }

    /// Half an ellipse between two points on one horizontal line, bulging up or down.
    private func halfEllipse(_ path: inout Path, from a: CGPoint, to b: CGPoint, ry: CGFloat, up: Bool) {
        let k: CGFloat = 0.5523
        let cx = (a.x + b.x) / 2, rx = (b.x - a.x) / 2
        let dy = up ? -ry : ry
        let top = CGPoint(x: cx, y: a.y + dy)
        path.addCurve(to: top, control1: CGPoint(x: a.x, y: a.y + dy * k),
                      control2: CGPoint(x: cx - rx * k, y: top.y))
        path.addCurve(to: b, control1: CGPoint(x: cx + rx * k, y: top.y),
                      control2: CGPoint(x: b.x, y: a.y + dy * k))
    }

    /// The dizzy spiral for error eyes: half-circles of growing radius, alternating sides.
    private func spiral(_ cx: CGFloat, _ cy: CGFloat) -> Path {
        var path = Path()
        var x = cx
        path.move(to: pt(x, cy))
        for i in 1...7 {
            let r = CGFloat(i) * 1.2
            let next = x + (i.isMultiple(of: 2) ? -1 : 1) * 2 * r
            // SVG sweep 1: rightward runs go over the top, leftward runs underneath.
            halfEllipse(&path, from: pt(x, cy), to: pt(next, cy), ry: r, up: next > x)
            x = next
        }
        return path
    }

    // MARK: Parts

    private var bodyPath: (path: Path, box: CGRect) {
        switch shape {
        case .blob:
            return (ellipse(60, 70, 44, 41), CGRect(x: 16, y: 29, width: 88, height: 82))
        case .pill:
            return (rounded(25, 22, 70, 88, 35), CGRect(x: 25, y: 22, width: 70, height: 88))
        case .ghost:
            var path = Path()
            path.move(to: pt(18, 68))
            halfEllipse(&path, from: pt(18, 68), to: pt(102, 68), ry: 40, up: true)
            path.addLine(to: pt(102, 104))
            // A scalloped hem: six soft bumps, alternating down and up.
            let xs: [CGFloat] = [102, 88, 74, 60, 46, 32, 18]
            for (i, (from, to)) in zip(xs, xs.dropFirst()).enumerated() {
                path.addQuadCurve(to: pt(to, 104),
                                  control: pt((from + to) / 2, i.isMultiple(of: 2) ? 113 : 95))
            }
            path.closeSubpath()
            return (path, CGRect(x: 18, y: 28, width: 84, height: 85))
        default:
            return (rounded(18, 30, 84, 79, 31), CGRect(x: 18, y: 30, width: 84, height: 79))
        }
    }

    private func drawBehind(in context: inout GraphicsContext) {
        switch shape {
        case .cat:
            for (outer, inner) in [([pt(23, 50), pt(29, 14), pt(55, 33)], [pt(31, 36), pt(33, 23), pt(43, 31)]),
                                   ([pt(97, 50), pt(91, 14), pt(65, 33)], [pt(89, 36), pt(87, 23), pt(77, 31)])] {
                var ear = line(outer); ear.closeSubpath()
                context.fill(ear, with: .color(ink.body))
                context.stroke(ear, with: .color(ink.body), style: round(7))
                var inside = line(inner); inside.closeSubpath()
                context.fill(inside, with: .color(ink.light))
                context.stroke(inside, with: .color(ink.light), style: round(3))
            }
        case .bunny:
            for (cx, angle) in [(CGFloat(40), -12.0), (CGFloat(80), 12.0)] {
                context.fill(rotated(ellipse(cx, 20, 10, 24), angle, about: pt(cx, 20)), with: .color(ink.body))
                context.fill(rotated(ellipse(cx, 20, 4.5, 16), angle, about: pt(cx, 20)), with: .color(ink.light))
            }
        case .bear:
            for cx: CGFloat in [28, 92] {
                context.fill(ellipse(cx, 36, 14, 14), with: .color(ink.body))
                context.fill(ellipse(cx, 36, 6.5, 6.5), with: .color(ink.dark.opacity(0.35)))
            }
        case .horns:
            var left = Path()
            left.move(to: pt(30, 42))
            left.addQuadCurve(to: pt(31, 12), control: pt(19, 22))
            left.addQuadCurve(to: pt(46, 34), control: pt(33, 28))
            left.closeSubpath()
            var right = Path()
            right.move(to: pt(90, 42))
            right.addQuadCurve(to: pt(89, 12), control: pt(101, 22))
            right.addQuadCurve(to: pt(74, 34), control: pt(87, 28))
            right.closeSubpath()
            context.fill(left, with: .color(ink.dark))
            context.fill(right, with: .color(ink.dark))
        default:
            break
        }
    }

    private func arm(_ x: CGFloat, _ y: CGFloat, _ rotation: Double, wave: Double = 0) -> Path {
        let tuck: CGFloat = shape == .pill ? 7 : 0
        let x = x < 60 ? x + tuck : x - tuck
        var path = rounded(x, y, 13, 26, 6.5)
        if wave != 0 { path = rotated(path, wave, about: pt(x + 6.5, y + 22.1)) }
        return rotated(path, rotation, about: pt(x + 6.5, y + 20))
    }

    private var arms: [Path] {
        switch mood {
        case .waitingForYou: [arm(10, 70, 28), arm(97, 30, 18, wave: motion.wave)]
        case .done: [arm(9, 33, -22), arm(98, 33, 22)]
        default: [arm(10, 70, 28), arm(97, 70, -28)]
        }
    }

    private var bulbColour: Color {
        switch mood {
        case .idle: ink.info
        case .working, .done: ink.success
        case .waitingForYou: .white
        case .sleeping: ink.muted
        case .failed: ink.destructive
        }
    }

    private func drawEyes(in context: inout GraphicsContext) {
        switch mood {
        case .done:
            context.stroke(quad(pt(35, 66), pt(46, 54), pt(57, 66)), with: .color(ink.pupil), style: round(4.2))
            context.stroke(quad(pt(63, 66), pt(74, 54), pt(85, 66)), with: .color(ink.pupil), style: round(4.2))
        case .sleeping:
            context.stroke(quad(pt(36, 63), pt(46, 70), pt(56, 63)), with: .color(ink.pupil), style: round(3.8))
            context.stroke(quad(pt(64, 63), pt(74, 70), pt(84, 63)), with: .color(ink.pupil), style: round(3.8))
        case .failed:
            for cx: CGFloat in [46, 74] {
                context.fill(ellipse(cx, 63, 12, 12), with: .color(.white))
                if mini {
                    // A spiral smudges into a grey dot this small; a cross still reads as "oops".
                    let width = atLeast(3.4, points: 1.1)
                    context.stroke(line([pt(cx - 5, 58), pt(cx + 5, 68)]), with: .color(ink.pupil), style: round(width))
                    context.stroke(line([pt(cx + 5, 58), pt(cx - 5, 68)]), with: .color(ink.pupil), style: round(width))
                } else {
                    context.stroke(rotated(spiral(cx - 0.6, 63), motion.spin, about: pt(cx, 63)),
                                   with: .color(ink.pupil), style: round(2.2))
                }
            }
        case .idle, .working, .waitingForYou:
            let look: CGPoint = switch mood {
            case .working: CGPoint(x: 3.6 + motion.dart.x, y: 3.4 + motion.dart.y)
            case .waitingForYou: CGPoint(x: 0, y: -2.2)
            default: CGPoint(x: 1.2, y: 1.4)
            }
            for cx: CGFloat in [46, 74] {
                var eye = context
                // The blink squeezes the whole eye towards its centre line.
                eye.translateBy(x: cx, y: 63)
                eye.scaleBy(x: 1, y: motion.blink)
                eye.translateBy(x: -cx, y: -63)
                eye.fill(ellipse(cx, 63, 11.5, 13.5), with: .color(.white))
                eye.fill(ellipse(cx + look.x, 63 + look.y, 6.4, 6.4), with: .color(ink.pupil))
                eye.fill(ellipse(cx + look.x + 2.3, 63 + look.y - 2.6, 2.2, 2.2), with: .color(.white))
            }
        }
    }

    private func drawBrows(in context: inout GraphicsContext) {
        switch mood {
        case .working:
            context.stroke(line([pt(35, 45), pt(54, 50)]), with: .color(ink.dark), style: round(3.4))
            context.stroke(line([pt(85, 45), pt(66, 50)]), with: .color(ink.dark), style: round(3.4))
        case .waitingForYou:
            let y = motion.browLift
            context.stroke(quad(pt(35, 44 + y), pt(44, 37 + y), pt(54, 42 + y)), with: .color(ink.dark), style: round(3.4))
            context.stroke(quad(pt(66, 42 + y), pt(76, 37 + y), pt(85, 44 + y)), with: .color(ink.dark), style: round(3.4))
        default:
            break
        }
    }

    private func drawMouth(in context: inout GraphicsContext) {
        switch mood {
        case .idle:
            context.stroke(quad(pt(53, 84), pt(60, 90.5), pt(67, 84)), with: .color(ink.mouth), style: round(3.6))
        case .working:
            context.stroke(line([pt(53, 86), pt(67, 85)]), with: .color(ink.mouth), style: round(3.6))
            context.fill(ellipse(64.5, 89, 3.6, 3.2), with: .color(ink.tongue))
        case .waitingForYou:
            context.fill(ellipse(60, 87, 4.8, 6), with: .color(ink.mouth))
        case .done:
            var grin = quad(pt(48, 81), pt(60, 100), pt(72, 81))
            grin.closeSubpath()
            context.fill(grin, with: .color(ink.mouth))
            context.fill(ellipse(60, 89.5, 5.5, 3.2), with: .color(ink.tongue))
        case .sleeping:
            context.fill(ellipse(60, 86, 3.2, 2.6), with: .color(ink.mouth))
        case .failed:
            context.stroke(line([pt(48, 87), pt(52, 83), pt(56, 87), pt(60, 83), pt(64, 87), pt(68, 83), pt(72, 87)]),
                           with: .color(ink.mouth), style: round(3.2))
        }
    }

    private func drawExtras(in context: inout GraphicsContext) {
        switch mood {
        case .working:
            // A bead of sweat sliding down beside the head.
            let p = motion.progress(period: 1.3, delay: 0)
            let eased = p * p
            let opacity = p < 0.25 ? p / 0.25 : 1 - (p - 0.25) / 0.75
            var drop = Path()
            drop.move(to: pt(101, 41))
            drop.addQuadCurve(to: pt(101, 52), control: pt(106.5, 48.5))
            drop.addQuadCurve(to: pt(101, 41), control: pt(95.5, 48.5))
            context.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: 0, y: CGFloat(-2 + 11 * eased))
                layer.fill(drop, with: .color(ink.sweat))
            }
        case .waitingForYou:
            context.drawLayer { layer in
                layer.opacity = 0.35 + 0.65 * Double(MascotMotion.alternate(motion.time, period: 0.45))
                for (a, b) in [(pt(94, 12), pt(91, 6)), (pt(104, 9), pt(105, 2)), (pt(113, 14), pt(118, 9))] {
                    layer.stroke(line([a, b]), with: .color(ink.body), style: round(3))
                }
            }
        case .done:
            for (i, s) in [(CGFloat(14), CGFloat(46), CGFloat(7)), (106, 14, 6.5), (112, 60, 5), (24, 14, 4.5)].enumerated() {
                let p = motion.progress(period: 1.4, delay: Double(i) * 0.25)
                let scale = MascotMotion.keyframes(p, period: 1, [(0, 0), (0.4, 1.15), (0.7, 0.9), (1, 0)])
                let opacity = MascotMotion.keyframes(p, period: 1, [(0, 0), (0.4, 1), (0.7, 0.9), (1, 0)])
                let turn = MascotMotion.keyframes(p, period: 1, [(0, 0), (0.4, 25), (0.7, 45), (1, 45)])
                guard scale > 0.01 else { continue }
                context.drawLayer { layer in
                    layer.opacity = opacity
                    layer.translateBy(x: s.0, y: s.1)
                    layer.rotate(by: .degrees(turn))
                    layer.scaleBy(x: scale, y: scale)
                    layer.fill(star(0, 0, s.2), with: .color(ink.spark))
                }
            }
        case .sleeping:
            for (i, z) in [(CGFloat(86), CGFloat(14), CGFloat(1)), (97, 6, 0.75), (106, 0, 0.55)].enumerated() {
                let p = motion.progress(period: 2.7, delay: Double(i) * 0.9)
                let opacity = p < 0.3 ? p / 0.3 : 1 - (p - 0.3) / 0.7
                let letter = line([pt(z.0, z.1 + 4), pt(z.0 + 7 * z.2, z.1 + 4),
                                   pt(z.0, z.1 + 4 + 8 * z.2), pt(z.0 + 7 * z.2, z.1 + 4 + 8 * z.2)])
                context.drawLayer { layer in
                    layer.opacity = opacity
                    layer.translateBy(x: CGFloat(7 * p), y: CGFloat(4 - 14 * p))
                    layer.stroke(letter, with: .color(ink.muted), style: round(2.2))
                }
            }
            // The snore bubble swells and pops.
            let p = motion.progress(period: 4.2, delay: 0)
            let s = MascotMotion.keyframes(p, period: 1, [(0, 0.35), (0.55, 1.25), (0.62, 0.3), (1, 0.35)])
            let bubble = ellipse(69, 83, 5 * s, 5 * s)
            context.fill(bubble, with: .color(MascotRGB.hex(0xCFEEFF).color.opacity(0.75)))
            context.stroke(bubble, with: .color(.white), lineWidth: 1.2)
        default:
            break
        }
    }

    // MARK: Draw

    func draw(in context: inout GraphicsContext) {
        if !mini {
            context.fill(ellipse(60, 113, 28, 3.6), with: .color(ink.shadow))
        }

        if mood == .failed && !mini {
            for angle in [0.0, 120, 240] {
                let r = (angle + motion.orbit) * .pi / 180
                context.fill(star(60 + 24 * CGFloat(cos(r)), 20 + 24 * CGFloat(sin(r)), 5), with: .color(ink.spark))
            }
        }

        var fig = context
        // The figure pivots at its feet, the way the design system's transform-origin does.
        fig.translateBy(x: 60 + motion.shiftX, y: 112 - motion.lift)
        fig.rotate(by: .degrees(motion.tilt))
        fig.scaleBy(x: motion.scaleX, y: motion.scaleY)
        fig.translateBy(x: -60, y: -112)

        drawBehind(in: &fig)

        if shape != .ghost {
            fig.fill(ellipse(45, 107, 9.5, 5.8), with: .color(ink.dark))
            fig.fill(ellipse(75, 107, 9.5, 5.8), with: .color(ink.dark))
        }
        for path in arms { fig.fill(path, with: .color(ink.body)) }

        let sleepy = mood == .sleeping
        let antenna = sleepy ? quad(pt(60, 31), pt(63, 19), pt(76, 21)) : quad(pt(60, 31), pt(57, 20), pt(65, 13))
        let bulbAt = sleepy ? pt(78, 22) : pt(66, 12)
        fig.stroke(antenna, with: .color(ink.dark), style: round(atLeast(3.2, points: 1.1)))
        let bulbRadius = atLeast(5.6, points: 1.6)
        let bulb = ellipse(bulbAt.x, bulbAt.y, bulbRadius, bulbRadius)
        fig.drawLayer { layer in
            layer.opacity = motion.bulbOpacity
            layer.fill(bulb, with: .color(bulbColour))
            if mood == .waitingForYou {
                layer.stroke(bulb, with: .color(ink.dark), lineWidth: 1.6)
            }
        }

        let (body, box) = bodyPath
        fig.fill(body, with: .radialGradient(
            Gradient(colors: [ink.light, ink.body]),
            center: CGPoint(x: box.minX + box.width * 0.42, y: box.minY + box.height * 0.34),
            startRadius: 0, endRadius: max(box.width, box.height) * 0.72))

        fig.fill(ellipse(31, 80, 6, 3.6), with: .color(ink.dark.opacity(0.22)))
        fig.fill(ellipse(89, 80, 6, 3.6), with: .color(ink.dark.opacity(0.22)))
        drawEyes(in: &fig)
        drawBrows(in: &fig)
        drawMouth(in: &fig)

        if !mini { drawExtras(in: &context) }
    }
}

// MARK: - Still faces

/// Small still faces for inline mentions, rendered once per look and reused.
///
/// `Text` cannot hold a view, only an image, so a mention's face is drawn to an image the first
/// time it is needed. Keyed by everything that changes the face, so a new pick redraws it.
@MainActor
enum MentionFaces {
    private static var cache: [String: NSImage] = [:]

    /// `scheme` nil follows the app's current appearance. An image render has no view tree to
    /// read it from, so without this every mention face came out in its light colours.
    static func image(for bot: Bot, size: CGFloat, scheme: ColorScheme? = nil) -> NSImage? {
        let shape = bot.avatarShape ?? BotFace.derivedShape(forHue: bot.avatarHue)
        let colour = bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue)
        let resolved = scheme ?? StillBotFace.appScheme
        let key = "\(shape.rawValue)-\(colour)-\(size)-\(resolved == .dark ? "dark" : "light")"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: StillBotFace(shape: shape, colour: colour, size: size,
                                                           scheme: resolved))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        cache[key] = image
        return image
    }
}

/// A face held still at one moment, for the app icon and other one-off renders, where a
/// `TimelineView` has no timeline to run on.
///
/// The face's `draw` runs outside the tree here, so its own environment is never filled in. The
/// colour scheme is passed explicitly: `scheme` when given (image renders), otherwise this view's
/// own environment, which is real because this view is in the tree.
struct StillBotFace: View {
    let shape: BotShape
    let colour: Int
    var size: CGFloat
    var mood: BotMood = .idle
    var at: TimeInterval = 0.4
    var scheme: ColorScheme?

    @Environment(\.colorScheme) private var colorScheme

    init(shape: BotShape, colour: Int, size: CGFloat, mood: BotMood = .idle,
         at: TimeInterval = 0.4, scheme: ColorScheme? = nil) {
        self.shape = shape
        self.colour = colour
        self.size = size
        self.mood = mood
        self.at = at
        self.scheme = scheme
    }

    private var face: BotFace {
        var face = BotFace(hue: 0.5, mood: mood, size: size, shape: shape, colour: colour, still: true)
        face.scheme = scheme ?? colorScheme
        return face
    }

    var body: some View {
        let face = self.face
        let time = at
        Canvas { context, canvas in face.draw(in: &context, size: canvas, time: time) }
            .frame(width: size, height: size)
    }

    /// The app's appearance right now, for renders made outside any window.
    @MainActor
    static var appScheme: ColorScheme {
        let match = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }
}

// MARK: - Shapes

/// The eight body shapes. Every one keeps the antenna: it is the status light, not decoration.
enum BotShape: String, CaseIterable, Sendable {
    case bup, blob, pill, cat, bunny, bear, ghost, horns

    /// A word for the picker. Plain, because these are characters, not geometry.
    var label: String {
        switch self {
        case .horns: "Imp"
        default: rawValue.capitalized
        }
    }

    /// The eight bot colours from the design system (`--bot-1` to `--bot-8`): one lightness and
    /// chroma, spread round the hue wheel, so no bot outshouts another.
    static let rgbPalette: [MascotRGB] = [
        .hex(0xD46EBD), .hex(0x9F82F0), .hex(0x4C99F8), .hex(0x00AFD5),
        .hex(0x00B67F), .hex(0x82A821), .hex(0xD58300), .hex(0xEA6A64),
    ]

    static let colourNames = ["Pink", "Violet", "Blue", "Teal", "Green", "Lime", "Amber", "Coral"]

    static let palette: [Color] = rgbPalette.map(\.color)
}

/// A calm, breathing glow around the composer while a bot works, in the app's accent.
///
/// Under Reduce Motion it holds still: a plain accent border that says the same thing without
/// pulsing.
struct BorderBeam: ViewModifier {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var hue: Double = 0.58
    var cornerRadius: CGFloat = Theme.Radius.lg
    var period: Double = 2.4
    /// Drawn only while true. The modifier itself stays applied either way, so turning it on
    /// and off never changes the identity of the view it decorates (which took focus out of the
    /// composer every time a run started or ended).
    var active: Bool = true

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                if reduceMotion {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(palette.primary.opacity(0.6), lineWidth: 1.5)
                        .allowsHitTesting(false)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period
                        // 0 to 1 to 0, eased, so it lingers at the ends of the breath.
                        let breath = 0.5 - 0.5 * cos(phase * 2 * .pi)
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(palette.primary.opacity(0.35 + 0.45 * breath), lineWidth: 1.5)
                            .shadow(color: palette.primary.opacity(0.18 + 0.27 * breath), radius: 4 + 6 * breath)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

extension View {
    /// Always applies the beam and lets `active` decide whether it draws. An idle composer still
    /// costs no animation frames: the timeline only exists while active.
    func borderBeam(hue: Double, active: Bool, cornerRadius: CGFloat = Theme.Radius.lg) -> some View {
        modifier(BorderBeam(hue: hue, cornerRadius: cornerRadius, active: active))
    }
}
