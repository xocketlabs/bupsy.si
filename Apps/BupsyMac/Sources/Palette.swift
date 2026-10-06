import SwiftUI

/// The colour system, ported from the Agndex dashboard on watermelon.sh.
///
/// Values were converted from its oklch tokens to sRGB rather than eyeballed, so the result is
/// the same palette rather than an impression of it.
///
/// The idea worth keeping is the **inverted layering**. Most Mac apps make the sidebar lighter
/// than the content; this makes it darker, and then lifts cards *above* the background:
///
///     sidebar  #101010   ← darkest, recedes
///     content  #202020
///     card     #292929   ← lifted, catches the eye
///     hover    #343434
///
/// Depth comes from those four steps, which means almost nothing needs a border or a shadow, and
/// the one saturated colour in the palette has no competition when it does appear.
enum Palette {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// Picks between the two schemes. Taken from the environment at the top of a view rather than
    /// read per-colour, so one place decides and the rest just read tokens.
    struct Scheme {
        let background: Color
        let sidebar: Color
        let card: Color
        let cardHover: Color
        let popover: Color
        let secondary: Color
        let foreground: Color
        let mutedForeground: Color
        let sidebarMuted: Color
        let sidebarMutedForeground: Color
        let sidebarAccent: Color
        let sidebarBadge: Color
        let primary: Color
        let info: Color
        let destructive: Color
        let border: Color
        /// Done, connected, allowed. Darker in light mode so it passes on white.
        let success: Color
        let warning: Color
        /// `info` and `destructive` tuned for text: the raw tokens fail contrast on dark cards.
        let infoText: Color
        let destructiveText: Color
        /// Readable text on top of `primary`, per the design's `--primary-foreground`: near white
        /// in light mode, near black in dark mode, where the pink is lighter.
        let onPrimary: Color
        /// A switch's track while it is off (the design's `--chart-4`). On is `foreground`.
        let switchOff: Color
    }

    static let dark = Scheme(
        background: rgb(32, 32, 32),
        sidebar: rgb(16, 16, 16),
        card: rgb(41, 41, 41),
        cardHover: rgb(52, 52, 52),
        popover: rgb(23, 23, 23),
        secondary: rgb(38, 38, 38),
        foreground: rgb(250, 250, 250),
        mutedForeground: rgb(161, 161, 161),
        sidebarMuted: rgb(109, 109, 109),
        sidebarMutedForeground: rgb(166, 166, 166),
        sidebarAccent: rgb(52, 52, 52),
        sidebarBadge: rgb(32, 32, 32),
        primary: rgb(224, 117, 200),
        info: rgb(140, 75, 255),
        destructive: rgb(225, 11, 5),
        border: Color.white.opacity(0.10),
        success: rgb(51, 183, 95),
        warning: rgb(222, 144, 22),
        infoText: rgb(173, 144, 255),
        destructiveText: rgb(255, 117, 110),
        onPrimary: rgb(23, 23, 23),
        switchOff: rgb(82, 82, 82)
    )

    static let light = Scheme(
        background: rgb(255, 255, 255),
        sidebar: rgb(250, 250, 250),
        card: rgb(245, 245, 245),
        cardHover: rgb(235, 235, 235),
        popover: rgb(255, 255, 255),
        secondary: rgb(245, 245, 245),
        foreground: rgb(10, 10, 10),
        mutedForeground: rgb(115, 115, 115),
        sidebarMuted: rgb(115, 115, 115),
        sidebarMutedForeground: rgb(85, 85, 85),
        sidebarAccent: rgb(235, 235, 235),
        sidebarBadge: rgb(232, 232, 232),
        primary: rgb(215, 106, 191),
        info: rgb(140, 75, 255),
        destructive: rgb(225, 11, 5),
        border: Color.black.opacity(0.08),
        success: rgb(0, 124, 50),
        warning: rgb(162, 87, 0),
        infoText: rgb(129, 65, 238),
        destructiveText: rgb(206, 28, 18),
        onPrimary: rgb(250, 250, 250),
        switchOff: rgb(212, 212, 212)
    )

    static func scheme(for colorScheme: ColorScheme) -> Scheme {
        colorScheme == .dark ? dark : light
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
