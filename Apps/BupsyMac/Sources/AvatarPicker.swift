import SwiftUI

/// Choose a bot's face: one of the eight shapes, in one of the eight bot colours.
///
/// Every shape is shown as a face in the colour being considered, rather than as a grey outline
/// in a list: you are picking a character, and it should look like one while you choose. Shapes
/// another bot already wears carry a small dot in that bot's colour. They stay choosable: keeping
/// a roster varied is a nudge, and two bots that are deliberately twins is a thing someone might
/// want.
struct AvatarPicker: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var shape: BotShape
    @Binding var colour: Int
    /// Shapes other bots are wearing, to mark rather than forbid.
    var taken: Set<BotShape> = []
    /// The colour of the bot wearing each taken shape, for its dot. Missing entries get grey.
    var wearers: [BotShape: Color] = [:]
    var onChange: () -> Void = {}

    private let faceSize: CGFloat = 44
    private let swatchSize: CGFloat = 28
    private let columns = Array(repeating: GridItem(.flexible(minimum: 52), spacing: Theme.Space.tight), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                label("Shape")
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.tight) {
                    ForEach(BotShape.allCases, id: \.self) { option in
                        shapeTile(option)
                    }
                }
                if !taken.isEmpty {
                    Text("A dot in a bot's colour means that bot already wears it.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                label("Colour")
                // "Surprise me" sits after the swatches, and drops to its own line only when the
                // column is too narrow for both, as the board's wrapping row does.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.snug) {
                        swatches
                        surpriseButton
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.snug) {
                        swatches
                        surpriseButton
                    }
                }
            }
        }
    }

    private var swatches: some View {
        HStack(spacing: Theme.Space.snug) {
            ForEach(BotShape.palette.indices, id: \.self) { index in
                swatch(index)
            }
        }
        // Room for the selection ring, which is drawn outside the swatch.
        .padding(.vertical, 3)
        .fixedSize()
    }

    private var surpriseButton: some View {
        Button(action: shuffle) {
            Label("Surprise me", systemImage: "sparkle")
        }
        .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .sm))
        .fixedSize()
        .help("Pick a random face nobody else is wearing")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(palette.mutedForeground)
    }

    private func shapeTile(_ option: BotShape) -> some View {
        let selected = option == shape
        let worn = taken.contains(option) && !selected
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) { shape = option }
            onChange()
        } label: {
            VStack(spacing: Theme.Space.hairline) {
                StillBotFace(shape: option, colour: colour, size: faceSize)
                Text(option.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.snug)
            .padding(.bottom, Theme.Space.tight)
            .background(selected ? palette.background : palette.card,
                        in: .rect(cornerRadius: Theme.Radius.base))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.base)
                    .strokeBorder(selected ? palette.foreground : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if worn {
                    Circle()
                        .fill(wearers[option] ?? palette.mutedForeground)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(palette.card, lineWidth: 2).padding(-2))
                        .padding(Theme.Space.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(worn ? "\(option.label), another bot wears this" : option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatch(_ index: Int) -> some View {
        let selected = index == colour
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { colour = index }
            onChange()
        } label: {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(BotShape.palette[index])
                .frame(width: swatchSize, height: swatchSize)
                .overlay {
                    // Outside the swatch, so it keeps its full 28pt of colour when picked.
                    RoundedRectangle(cornerRadius: Theme.Radius.control + 3)
                        .strokeBorder(selected ? palette.foreground : Color.clear, lineWidth: 2)
                        .padding(-3)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(index < BotShape.colourNames.count ? BotShape.colourNames[index] : "")
        .accessibilityLabel(index < BotShape.colourNames.count ? BotShape.colourNames[index] : "Colour")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func shuffle() {
        let free = BotShape.allCases.filter { $0 != shape && !taken.contains($0) }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
            shape = (free.isEmpty ? BotShape.allCases.filter { $0 != shape } : free).randomElement() ?? shape
            colour = BotShape.palette.indices.filter { $0 != colour }.randomElement() ?? colour
        }
        onChange()
    }
}

/// The design system's ghost button: no fill until the pointer is over it.
struct AvatarPickerGhostButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((hovering || configuration.isPressed) ? palette.foreground.opacity(0.07) : .clear,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .onHover { hovering = $0 }
    }
}
