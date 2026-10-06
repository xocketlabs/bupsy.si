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
    @Binding var shape: BotShape
    @Binding var colour: Int
    /// Shapes other bots are wearing, to mark rather than forbid.
    var taken: Set<BotShape> = []
    /// The colour of the bot wearing each taken shape, for its dot. Missing entries get grey.
    var wearers: [BotShape: Color] = [:]
    var onChange: () -> Void = {}

    private let faceSize: CGFloat = 40
    private let columns = Array(repeating: GridItem(.flexible(minimum: 52), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                label("Shape")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
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
                HStack(spacing: 4) {
                    ForEach(BotShape.palette.indices, id: \.self) { index in
                        swatch(index)
                    }
                }
                Button(action: shuffle) {
                    Label("Surprise me", systemImage: "sparkle")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .padding(.horizontal, Theme.Space.snug)
                        .frame(height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Pick a random face nobody else is wearing")
            }
        }
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { shape = option }
            onChange()
        } label: {
            VStack(spacing: 2) {
                StillBotFace(shape: option, colour: colour, size: faceSize)
                Text(option.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 6)
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
                        .padding(6)
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
            withAnimation(.easeOut(duration: 0.15)) { colour = index }
            onChange()
        } label: {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(BotShape.palette[index])
                .frame(width: 26, height: 26)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control + 3)
                        .strokeBorder(selected ? palette.foreground : Color.clear, lineWidth: 2)
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            shape = (free.isEmpty ? BotShape.allCases.filter { $0 != shape } : free).randomElement() ?? shape
            colour = BotShape.palette.indices.filter { $0 != colour }.randomElement() ?? colour
        }
        onChange()
    }
}
