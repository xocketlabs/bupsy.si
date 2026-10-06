import BupsyKit
import SwiftUI

/// Making or editing a bot, on one screen.
///
/// Two columns in the app's sheet. On the left the bot itself, live on a tinted stage and
/// reacting as you go (asleep until it has a name, upset if the name is taken), with the shapes
/// and colours beneath it. On the right who it is (name, role, section, job) and how it runs
/// (engine, model, trust). Used for "Set up a bot yourself" and for Edit.
struct BotCreatorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// The bot being edited, or nil to make a new one.
    var editing: Bot? = nil
    /// A name to start a new bot with, such as what was typed into the palette.
    var initialName: String? = nil

    @State private var name = ""
    @State private var role = ""
    @State private var job = ""
    /// The section it is filed in. Empty means unassigned.
    @State private var folder = ""
    @State private var typingNewSection = false
    @State private var engine = EngineID.claude
    @State private var modelID: String?
    @State private var trust = Autonomy.ask
    @State private var shape = BotShape.bup
    @State private var colour = 8
    @State private var faceChanged = false
    @State private var loaded = false

    init(editing: Bot? = nil, name: String? = nil) {
        self.editing = editing
        self.initialName = name
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedFolder: String { folder.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool { model.isNameTaken(name, except: editing?.id) }
    private var others: [Bot] { model.bots.filter { $0.id != editing?.id } }
    private var taken: Set<BotShape> { Set(others.map(\.effectiveShape)) }

    /// The colour of the first other bot wearing each shape, for the dot on its tile.
    private var wearers: [BotShape: Color] {
        var result: [BotShape: Color] = [:]
        for bot in others where result[bot.effectiveShape] == nil {
            result[bot.effectiveShape] = BotFace.colour(of: bot)
        }
        return result
    }

    private var safeColour: Int { ((colour % BotShape.palette.count) + BotShape.palette.count) % BotShape.palette.count }
    private var tint: Color { BotShape.palette[safeColour] }

    var body: some View {
        SheetFrame(title: displayName,
                   icon: editing == nil ? "plus.circle" : "pencil",
                   subtitle: "Pick its face, give it a job, choose how careful it is.",
                   width: 760,
                   tone: .primary,
                   primaryVerb: editing == nil ? "create" : "save") {
            HStack(alignment: .top, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                    preview
                    AvatarPicker(shape: $shape, colour: $colour, taken: taken, wearers: wearers,
                                 onChange: { faceChanged = true })
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                fields
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button(editing == nil ? "Create bot" : "Save", action: save)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || nameTaken)
        }
        .onAppear(perform: load)
    }

    private var displayName: String {
        trimmedName.isEmpty ? (editing == nil ? "New bot" : "Edit bot") : trimmedName
    }

    // MARK: - Preview

    /// The bot, live, on a stage in its own colour.
    private var preview: some View {
        VStack(spacing: 10) {
            BotFace(hue: 0.5, mood: previewMood, size: 120, shape: shape, colour: safeColour)
            VStack(spacing: 1) {
                Text(displayName)
                    .font(.system(size: Theme.scaled(14), weight: .medium))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                Text(previewCaption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(nameTaken ? palette.destructiveText : palette.mutedForeground)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .padding(.horizontal, Theme.Space.step)
        .background { MascotStageBackground(tint: tint, cornerRadius: 14) }
        .animation(.easeOut(duration: 0.2), value: safeColour)
    }

    private var previewMood: BotMood {
        if nameTaken { return .failed }
        if trimmedName.isEmpty { return .sleeping }
        return .idle
    }

    private var previewCaption: String {
        if nameTaken { return "Pick another name" }
        if trimmedName.isEmpty { return "Waiting for a name" }
        let trimmedRole = role.trimmingCharacters(in: .whitespaces)
        switch (trimmedRole.isEmpty, trimmedFolder.isEmpty) {
        case (false, false): return "\(trimmedRole) in \(trimmedFolder)"
        case (false, true): return trimmedRole
        case (true, false): return "In \(trimmedFolder)"
        case (true, true): return engine.displayName
        }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Field(label: "Name") {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    TextField("", text: $name, prompt: Text("Give it a name"))
                        .textFieldStyle(BupsyFieldStyle())
                    if nameTaken {
                        Text("Another bot is already called that.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.destructiveText)
                    }
                }
            }

            HStack(alignment: .top, spacing: Theme.Space.step) {
                Field(label: "Role") {
                    TextField("", text: $role, prompt: Text("Research, PA..."))
                        .textFieldStyle(BupsyFieldStyle())
                }
                .frame(maxWidth: .infinity)
                Field(label: "Section") { sectionControl }
                    .frame(maxWidth: .infinity)
            }

            Field(label: "Job") {
                TextField("", text: $job,
                          prompt: Text("What should it do? e.g. watch my inbox and flag anything urgent"),
                          axis: .vertical)
                    .textFieldStyle(BupsyFieldStyle())
                    .lineLimit(3...5)
            }

            HStack(alignment: .top, spacing: Theme.Space.step) {
                Field(label: "Engine") {
                    selectField(engine.displayName) {
                        ForEach(EngineID.supported, id: \.self) { option in
                            Button {
                                engine = option
                                modelID = nil
                            } label: {
                                Label(option.displayName, systemImage: engine == option ? "checkmark" : "")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                Field(label: "Model") {
                    selectField(modelLabel) {
                        ForEach(modelOptions) { option in
                            Button { modelID = option.id } label: {
                                Label(option.label, systemImage: modelID == option.id ? "checkmark" : "")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Field(label: "Trust", hint: "If nobody answers when it asks, the answer is no.") {
                selectField(trust.menuLabel, tone: trust == .auto ? palette.destructiveText : nil) {
                    ForEach(Autonomy.allCases, id: \.self) { level in
                        Button { trust = level } label: {
                            Label(level.menuLabel, systemImage: trust == level ? "checkmark" : "")
                        }
                    }
                }
            }
        }
    }

    /// A menu of the sections in use, or a field for a new one.
    @ViewBuilder
    private var sectionControl: some View {
        if typingNewSection {
            HStack(spacing: Theme.Space.tight) {
                TextField("", text: $folder, prompt: Text("Section name"))
                    .textFieldStyle(BupsyFieldStyle())
                Button {
                    typingNewSection = false
                    if !sections.contains(trimmedFolder) { folder = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.scaled(10), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Pick an existing section")
            }
        } else {
            selectField(trimmedFolder.isEmpty ? "Unassigned" : trimmedFolder) {
                ForEach(sections, id: \.self) { section in
                    Button { folder = section } label: {
                        Label(section, systemImage: trimmedFolder == section ? "checkmark" : "")
                    }
                }
                Button { folder = "" } label: {
                    Label("Unassigned", systemImage: trimmedFolder.isEmpty ? "checkmark" : "")
                }
                Divider()
                Button("New section...") {
                    folder = ""
                    typingNewSection = true
                }
            }
        }
    }

    /// The sections in use, plus the one this bot is already in if the list leaves it out.
    private var sections: [String] {
        var list = model.folders
        let current = editing.flatMap { edited in model.bots.first { $0.id == edited.id } }?.folder ?? ""
        if !current.isEmpty && !list.contains(current) { list.append(current) }
        return list
    }

    /// A menu that looks like a field: the value on the left, a chevron on the right.
    ///
    /// The field look is drawn behind the menu rather than in its label, because a
    /// `.borderlessButton` menu sizes its label to the text and would not stretch the background.
    private func selectField<Items: View>(_ value: String, tone: Color? = nil,
                                          @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Text(value)
                .font(Theme.Typography.body)
                .foregroundStyle(tone ?? palette.foreground)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Theme.Space.step)
        .padding(.trailing, 28)
        .frame(height: 38)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(palette.border)
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down")
                .font(.system(size: Theme.scaled(9), weight: .semibold))
                .foregroundStyle(palette.mutedForeground)
                .padding(.trailing, Theme.Space.step)
                .allowsHitTesting(false)
        }
    }

    private var modelOptions: [ModelOption] {
        model.models(for: Bot(name: "preview", engine: engine))
    }

    private var modelLabel: String {
        modelOptions.first { $0.id == modelID }?.label ?? modelID ?? "Default"
    }

    // MARK: - Load and save

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let bot = editing.flatMap({ edited in model.bots.first { $0.id == edited.id } }) ?? editing {
            name = bot.name
            role = bot.role ?? ""
            job = bot.personaPrompt ?? ""
            folder = bot.folder ?? ""
            engine = bot.engine
            modelID = bot.model
            trust = bot.autonomy
            shape = bot.effectiveShape
            colour = bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue)
        } else {
            if let initialName { name = initialName }
            // A fresh bot starts on a shape nobody else wears.
            shape = BotShape.allCases.first { !taken.contains($0) } ?? .bup
            colour = Int.random(in: 0..<BotShape.palette.count - 1)
        }
    }

    private func save() {
        let section: String? = trimmedFolder.isEmpty ? nil : trimmedFolder
        if let editing, let bot = model.bots.first(where: { $0.id == editing.id }) {
            model.rename(bot, to: trimmedName)
            model.setJob(bot, job)
            model.setRole(bot, role)
            if faceChanged { model.setAvatar(bot, shape: shape, colour: safeColour) }
            if bot.engine != engine { model.setEngine(bot, engine) }
            model.setModel(bot, modelID)
            model.setAutonomy(bot, trust)
            if (bot.folder ?? "") != (section ?? "") { model.setFolder(bot, section) }
        } else {
            model.addBot(name: trimmedName, engine: engine, job: job.trimmingCharacters(in: .whitespaces),
                         folder: section, shape: shape, colour: safeColour)
            if let bot = model.bots.first(where: { $0.name == trimmedName }) {
                model.setRole(bot, role)
                model.setModel(bot, modelID)
                if trust != .ask { model.setAutonomy(bot, trust) }
            }
        }
        dismiss()
    }
}
