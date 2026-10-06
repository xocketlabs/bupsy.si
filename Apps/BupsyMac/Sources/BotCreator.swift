import BupsyKit
import SwiftUI

/// Making or editing a bot, on one screen.
///
/// The face is the centrepiece: large, live, with every shape in a ring around it to pick from
/// and the colours beneath. Then who it is (name, role, job) as a tidy card of rows, and how it
/// runs (engine, model, trust) as another. Used for "Set up a bot yourself" and for Edit.
struct BotCreatorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// The bot being edited, or nil to make a new one.
    var editing: Bot? = nil

    @State private var name = ""
    @State private var role = ""
    @State private var job = ""
    @State private var engine = EngineID.claude
    @State private var modelID: String?
    @State private var trust = Autonomy.ask
    @State private var shape = BotShape.bup
    @State private var colour = 8
    @State private var faceChanged = false
    @State private var loaded = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool { model.isNameTaken(name, except: editing?.id) }
    private var taken: Set<BotShape> { Set(model.bots.filter { $0.id != editing?.id }.map(\.effectiveShape)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    FaceRing(shape: $shape, colour: colour, taken: taken) { faceChanged = true }
                    ColourRow(colour: $colour, onShuffle: shuffle) { faceChanged = true }
                    identity
                    preferences
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
            Rectangle().fill(palette.border).frame(height: 1)
            HStack(spacing: Theme.Space.snug) {
                if nameTaken {
                    Text("Another bot is already called that.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.destructive)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.buttonStyle(QuietButton())
                Button(editing == nil ? "Create bot" : "Save", action: save)
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || nameTaken)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 640)
        .background(palette.popover)
        .onAppear(perform: load)
    }

    private var header: some View {
        ZStack {
            Text(trimmedName.isEmpty ? (editing == nil ? "New bot" : "Edit bot") : trimmedName)
                .font(.system(size: Theme.scaled(15), weight: .semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.scaled(10), weight: .bold))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 24, height: 24)
                        .background(palette.foreground.opacity(0.07), in: .circle)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var identity: some View {
        VStack(spacing: 0) {
            fieldRow("Name") {
                TextField("", text: $name, prompt: Text("Give it a name"))
            }
            divider
            fieldRow("Role") {
                TextField("", text: $role, prompt: Text("Research, PA, Finance…"))
            }
            divider
            fieldRow("Job", alignTop: true) {
                TextField("", text: $job, prompt: Text("What should it do? e.g. watch my inbox and flag anything urgent"),
                          axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        .padding(6)
        .background(palette.card, in: .rect(cornerRadius: 14))
    }

    private var preferences: some View {
        VStack(spacing: 0) {
            prefRow("cpu", "Engine", engine.displayName) {
                ForEach(EngineID.supported, id: \.self) { option in
                    Button { engine = option; modelID = nil } label: {
                        Label(option.displayName, systemImage: engine == option ? "checkmark" : "")
                    }
                }
            }
            divider
            prefRow("slider.horizontal.3", "Model", modelLabel) {
                ForEach(modelOptions) { option in
                    Button { modelID = option.id } label: {
                        Label(option.label, systemImage: modelID == option.id ? "checkmark" : "")
                    }
                }
            }
            divider
            prefRow("hand.raised", "Trust", trust.menuLabel) {
                ForEach(Autonomy.allCases, id: \.self) { level in
                    Button { trust = level } label: {
                        Label(level.menuLabel, systemImage: trust == level ? "checkmark" : "")
                    }
                }
            }
        }
        .padding(6)
        .background(palette.card, in: .rect(cornerRadius: 14))
    }

    private var divider: some View { Rectangle().fill(palette.border).frame(height: 1).padding(.horizontal, 8) }

    private func fieldRow<Field: View>(_ label: String, alignTop: Bool = false, @ViewBuilder field: () -> Field) -> some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 10) {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .frame(width: 64, alignment: .leading)
                .padding(.top, alignTop ? 7 : 0)
            field()
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(palette.foreground.opacity(0.06), in: .rect(cornerRadius: 8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func prefRow<Items: View>(_ icon: String, _ label: String, _ value: String,
                                      @ViewBuilder items: () -> Items) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(12)))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 18)
            Text(label).font(Theme.Typography.body).foregroundStyle(palette.foreground)
            Spacer(minLength: 0)
            Menu { items() } label: {
                HStack(spacing: 4) {
                    Text(value).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: Theme.scaled(8), weight: .semibold))
                }
                .font(Theme.Typography.caption.weight(.medium))
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(palette.popover, in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }

    private var modelOptions: [ModelOption] {
        model.models(for: Bot(name: "preview", engine: engine))
    }

    private var modelLabel: String {
        modelOptions.first { $0.id == modelID }?.label ?? modelID ?? "Default"
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let bot = editing.flatMap({ edited in model.bots.first { $0.id == edited.id } }) ?? editing {
            name = bot.name
            role = bot.role ?? ""
            job = bot.personaPrompt ?? ""
            engine = bot.engine
            modelID = bot.model
            trust = bot.autonomy
            shape = bot.effectiveShape
            colour = bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue)
        } else {
            // A fresh bot starts on a shape nobody else wears.
            shape = BotShape.allCases.first { !taken.contains($0) } ?? .bup
            colour = Int.random(in: 0..<BotShape.palette.count - 1)
        }
    }

    private func shuffle() {
        let free = BotShape.allCases.filter { $0 != shape && !taken.contains($0) }
        shape = (free.isEmpty ? BotShape.allCases : free).randomElement() ?? shape
        colour = Int.random(in: 0..<BotShape.palette.count)
        faceChanged = true
    }

    private func save() {
        if let editing, let bot = model.bots.first(where: { $0.id == editing.id }) {
            model.rename(bot, to: trimmedName)
            model.setJob(bot, job)
            model.setRole(bot, role)
            if faceChanged { model.setAvatar(bot, shape: shape, colour: colour) }
            if bot.engine != engine { model.setEngine(bot, engine) }
            model.setModel(bot, modelID)
            model.setAutonomy(bot, trust)
        } else {
            model.addBot(name: trimmedName, engine: engine, job: job.trimmingCharacters(in: .whitespaces),
                         shape: shape, colour: colour)
            if let bot = model.bots.first(where: { $0.name == trimmedName }) {
                model.setRole(bot, role)
                model.setModel(bot, modelID)
                if trust != .ask { model.setAutonomy(bot, trust) }
            }
        }
        dismiss()
    }
}

/// The big live face with every shape on a ring around it.
struct FaceRing: View {
    @Environment(\.palette) private var palette
    @Binding var shape: BotShape
    let colour: Int
    let taken: Set<BotShape>
    var onPick: () -> Void

    private let ring: CGFloat = 104
    private let small: CGFloat = 32

    var body: some View {
        let shapes = BotShape.allCases
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [BotShape.palette[colour % BotShape.palette.count].opacity(0.22), .clear],
                                     center: .center, startRadius: 0, endRadius: 90))
                .frame(width: 180, height: 180)
            BotFace(hue: 0.5, mood: .idle, size: 112, shape: shape, colour: colour)
                .id("\(shape.rawValue)-\(colour)")
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            ForEach(Array(shapes.enumerated()), id: \.element) { index, option in
                let angle = Double(index) / Double(shapes.count) * 2 * .pi - .pi / 2
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { shape = option }
                    onPick()
                } label: {
                    StillBotFace(shape: option, colour: colour, size: small)
                        .padding(3)
                        .background(Circle().fill(option == shape ? palette.primary.opacity(0.18) : .clear))
                        .overlay(Circle().strokeBorder(option == shape ? palette.primary : .clear, lineWidth: 1.5))
                        .overlay(alignment: .topTrailing) {
                            if taken.contains(option) && option != shape {
                                Circle().fill(palette.mutedForeground).frame(width: 5, height: 5)
                            }
                        }
                        .scaleEffect(option == shape ? 1.12 : 1)
                }
                .buttonStyle(.plain)
                .help(taken.contains(option) ? "\(option.label), another bot wears this" : option.label)
                .offset(x: cos(angle) * ring, y: sin(angle) * ring)
            }
        }
        .frame(width: ring * 2 + small + 12, height: ring * 2 + small + 12)
    }
}

/// The colour swatches, ending in a rainbow that shuffles the whole face.
struct ColourRow: View {
    @Environment(\.palette) private var palette
    @Binding var colour: Int
    var onShuffle: () -> Void
    var onPick: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(BotShape.palette.indices, id: \.self) { index in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { colour = index }
                    onPick()
                } label: {
                    Circle()
                        .fill(LinearGradient(colors: [BotShape.palette[index].opacity(0.85), BotShape.palette[index]],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 17, height: 17)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08)))
                        .padding(2)
                        .overlay(Circle().strokeBorder(index == colour ? palette.foreground : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            Button(action: onShuffle) {
                Circle()
                    .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                    .frame(width: 17, height: 17)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .help("Surprise me")
        }
    }
}
