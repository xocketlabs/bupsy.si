import SwiftUI

/// Bupsy's own face: the pink Bup with its violet antenna light, the mascot every bot is a
/// variation of. Drawn with the same `BotFace` code as the roster, so the mark, the icon and the
/// bots are one character at every size.
struct BupsyMark: View {
    var size: CGFloat = 24
    /// Alive in the sidebar (it breathes and blinks); still everywhere it is rendered once.
    var alive = false
    var mood: BotMood = .idle

    var body: some View {
        Group {
            if alive {
                BotFace(hue: 0, mood: mood, size: size, shape: .bup, colour: 0)
            } else {
                StillBotFace(shape: .bup, colour: 0, size: size, mood: mood)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("bupsy")
    }
}

/// The app icon: Bupsy rising out of the bottom edge of a charcoal macOS tile, its antenna light
/// glowing violet near the top. The face fills the tile so it still reads at 16pt in Finder.
///
/// Matches `bupsy-app-icon.svg` in the design system. Drawn on Apple's 1024 grid: an 824 tile
/// with 100 of margin, the drop shadow living in the margin.
struct BupsyAppIcon: View {
    private let tile = RoundedRectangle(cornerRadius: 186, style: .continuous)

    var body: some View {
        ZStack {
            tile.fill(LinearGradient(colors: [Color(white: 0.149), Color(white: 0.055)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 10)

            ZStack {
                // The light's glow, behind the antenna.
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.55, green: 0.29, blue: 1).opacity(0.55), .clear],
                                         center: .center, startRadius: 0, endRadius: 190))
                    .frame(width: 380, height: 380)
                    .offset(x: 43, y: -212)
                // Bupsy, large enough that its feet fall below the tile and are clipped.
                StillBotFace(shape: .bup, colour: 0, size: 828)
                    .offset(x: -4, y: 138)
            }
            .frame(width: 824, height: 824)
            .clipShape(tile)

            // A lit top rim and a darker bottom one, so the tile keeps its edge in a dark Dock.
            tile.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0), .black.opacity(0.25)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 4)
                .frame(width: 824, height: 824)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// The small mark beside the wordmark and in the sidebar header.
struct BupsyIconMark: View {
    var size: CGFloat = 26
    var alive = true

    var body: some View {
        BupsyMark(size: size, alive: alive)
    }
}
