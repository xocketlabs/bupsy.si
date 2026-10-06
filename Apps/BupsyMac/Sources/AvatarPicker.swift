import SwiftUI

/// Choose a bot's face: one of the eight shapes, in one of the eight bot colours.
///
/// Every shape is shown as a live face in the colour being considered, rather than as a grey
/// outline in a list — you are picking a character, and it should look like one while you choose.
/// Shapes another bot already wears carry a small dot. They stay choosable: keeping a roster
/// varied is a nudge, and two bots that are deliberately twins is a thing someone might want.
struct AvatarPicker: View {
    @Environment(\.palette) private var palette
    @Binding var shape: BotShape
    @Binding var colour: Int
    /// Shapes other bots are wearing, to mark rather than forbid.
    var taken: Set<BotShape> = []
    var onChange: () -> Void = {}

    private let faceSize: CGFloat = 40
    private let columns = Array(repeating: GridItem(.flexible(minimum: 52), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            HStack {
                Text("Face")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                Spacer(minLength: 0)
                Button {
                    shuffle()
                } label: {
                    Label("Shuffle", systemImage: "dice")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
                .buttonStyle(.plain)
                .help("Pick a random face nobody else is wearing")
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(BotShape.allCases, id: \.self) { option in
                    Button {
                        shape = option
                        onChange()
                    } label: {
                        BotFace(hue: 0, mood: .idle, size: faceSize, shape: option, colour: colour)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .fill(option == shape ? palette.cardHover : .clear))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .strokeBorder(option == shape ? palette.primary : .clear,
                                                  lineWidth: 1.5))
                            .overlay(alignment: .topTrailing) {
                                if taken.contains(option) && option != shape {
                                    Circle()
                                        .fill(palette.mutedForeground)
                                        .frame(width: 5, height: 5)
                                        .padding(3)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(taken.contains(option) ? "\(option.label), another bot wears this"
                                                 : option.label)
                }
            }

            HStack(spacing: 6) {
                ForEach(BotShape.palette.indices, id: \.self) { index in
                    Button {
                        colour = index
                        onChange()
                    } label: {
                        Circle()
                            .fill(BotShape.palette[index])
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        index == colour ? palette.foreground : palette.border,
                                        lineWidth: index == colour ? 2 : 1)
                                    .padding(index == colour ? -3 : 0))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }

    private func shuffle() {
        let free = BotShape.allCases.filter { $0 != shape && !taken.contains($0) }
        shape = (free.isEmpty ? BotShape.allCases.filter { $0 != shape } : free).randomElement() ?? shape
        colour = BotShape.palette.indices.filter { $0 != colour }.randomElement() ?? colour
        onChange()
    }
}
