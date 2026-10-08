import SwiftUI

/// The Mac app's colours (its `Palette.swift`), so the phone and the desk feel like one product.
///
/// The same inverted layering: the list sits on the darkest step, a chat on the next, and bubbles
/// and cards are lifted above it, so depth comes from the steps rather than borders and shadows,
/// and the one saturated colour, the pink, has no competition when it appears. The tints for
/// bubbles, cards and code are the web app's, which already worked out how faint each should be.
enum Palette {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: alpha)
    }

    struct Scheme {
        /// Behind a chat.
        let background: Color
        /// Behind the bot list and the pairing screen: one step darker than a chat.
        let sidebar: Color
        /// A bot's bubbles, chips and fields.
        let card: Color
        let cardHover: Color
        let foreground: Color
        let mutedForeground: Color
        let primary: Color
        /// Readable text on top of `primary`.
        let onPrimary: Color
        let success: Color
        let warning: Color
        /// The destructive red tuned for text, which the raw token fails on dark backgrounds.
        let destructiveText: Color
        let border: Color
        /// Your own bubbles: the pink, faint.
        let you: Color
        /// A card that waits on the person: a whisper of the pink, and its edge.
        let tint: Color
        let tintBorder: Color
        /// Code and commands, pressed into a bubble or card.
        let recess: Color
    }

    static let dark = Scheme(
        background: rgb(32, 32, 32),
        sidebar: rgb(16, 16, 16),
        card: rgb(41, 41, 41),
        cardHover: rgb(52, 52, 52),
        foreground: rgb(250, 250, 250),
        mutedForeground: rgb(161, 161, 161),
        primary: rgb(224, 117, 200),
        onPrimary: rgb(23, 23, 23),
        success: rgb(51, 183, 95),
        warning: rgb(222, 144, 22),
        destructiveText: rgb(255, 117, 110),
        border: Color.white.opacity(0.10),
        you: rgb(224, 117, 200, 0.26),
        tint: rgb(224, 117, 200, 0.10),
        tintBorder: rgb(224, 117, 200, 0.50),
        recess: Color.black.opacity(0.35)
    )

    static let light = Scheme(
        background: rgb(255, 255, 255),
        sidebar: rgb(250, 250, 250),
        card: rgb(245, 245, 245),
        cardHover: rgb(235, 235, 235),
        foreground: rgb(10, 10, 10),
        mutedForeground: rgb(115, 115, 115),
        primary: rgb(215, 106, 191),
        onPrimary: rgb(250, 250, 250),
        success: rgb(0, 124, 50),
        warning: rgb(162, 87, 0),
        destructiveText: rgb(206, 28, 18),
        border: Color.black.opacity(0.08),
        you: rgb(215, 106, 191, 0.14),
        tint: rgb(215, 106, 191, 0.07),
        tintBorder: rgb(215, 106, 191, 0.45),
        recess: Color.black.opacity(0.055)
    )

    static func scheme(for colorScheme: ColorScheme) -> Scheme {
        colorScheme == .dark ? dark : light
    }

    /// A bot's colour as the Mac sends it, `#rrggbb`. Nil for anything else, so a bad value
    /// falls back to a neutral rather than drawing black.
    static func colour(hex: String) -> Color? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return rgb((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    var palette: Palette.Scheme {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Resolves the palette once, at the root, and publishes it downward.
    func withPalette(_ colorScheme: ColorScheme) -> some View {
        environment(\.palette, Palette.scheme(for: colorScheme))
    }
}

/// The few measurements the app repeats, so a bubble and a card agree on what "rounded" means.
enum Theme {
    enum Radius {
        /// Buttons, fields, code blocks.
        static let control: CGFloat = 10
        /// Cards that wait on the person.
        static let card: CGFloat = 14
        static let bubble: CGFloat = 16
        /// The corner a run of bubbles points from, like a speech tail.
        static let tail: CGFloat = 5
    }

    enum Size {
        static let listAvatar: CGFloat = 44
        static let headerAvatar: CGFloat = 30
        /// Bubbles stop short of the far edge, so whose words are whose reads at a glance.
        static let bubbleInset: CGFloat = 48
        static let cardMaxWidth: CGFloat = 560
    }
}
