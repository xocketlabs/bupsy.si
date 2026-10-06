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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The bot being edited, or nil to make a new one.
    var editing: Bot? = nil
    /// A name to start a new bot with, such as what was typed into the palette.
    var initialName: String? = nil
    /// The section a new bot starts in, such as the one whose "+" opened this.
    var initialSection: String? = nil

    @State private var name = ""
    @State private var role = ""
    @State private var job = ""
    /// The section it is filed in. Empty means unassigned.
    @State private var folder = ""
    @State private var typingNewSection = false
    @State private var engine = EngineID.claude
    @State private var modelID: String?
    /// "Asks unless allowed", the same default as first run and the board.
    @State private var trust = Autonomy.allowlist
    @State private var shape = BotShape.bup
    @State private var colour = 0
    @State private var faceChanged = false
    @State private var loaded = false

    init(editing: Bot? = nil, name: String? = nil, section: String? = nil) {
        self.editing = editing
        self.initialName = name
        self.initialSection = section
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
        // The header tile is the bot, in the colour it is wearing, not a generic plus.
        SheetFrame(title: displayName,
                   icon: "face.smiling",
                   subtitle: "Pick its face, give it a job, choose how careful it is.",
                   width: 760,
                   tone: .primary,
                   primaryVerb: editing == nil ? "create" : "save",
                   tint: tint) {
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
        trimmedName.isEmpty ? (editing == nil ? "Set up a bot" : "Edit bot") : trimmedName
    }

    // MARK: - Preview

    /// The bot, live, on a stage in its own colour.
    private var preview: some View {
        VStack(spacing: Theme.Space.compact) {
            BotFace(hue: 0.5, mood: previewMood, size: 132, shape: shape, colour: safeColour)
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
        .background { MascotStageBackground(tint: tint, cornerRadius: Theme.Radius.xl) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: safeColour)
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
                        .bupsyField()
                    if nameTaken {
                        Text("Another bot is already called that.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.destructiveText)
                    }
                }
            }

            HStack(alignment: .top, spacing: Theme.Space.step) {
                Field(label: "Role") {
                    TextField("", text: $role, prompt: Text("Research, PA…"))
                        .bupsyField()
                }
                .frame(maxWidth: .infinity)
                Field(label: "Section") { sectionControl }
                    .frame(maxWidth: .infinity)
            }

            Field(label: "Job") {
                TextField("", text: $job,
                          prompt: Text("What should it do? e.g. watch my inbox and flag anything urgent"),
                          axis: .vertical)
                    .bupsyField()
                    .lineLimit(3...5)
            }

            HStack(alignment: .top, spacing: Theme.Space.step) {
                Field(label: "Engine") {
                    selectField(engine.displayName) {
                        ForEach(EngineID.supported, id: \.self) { option in
                            Toggle(isOn: Binding(
                                get: { engine == option },
                                set: { if $0 { engine = option; modelID = nil } })) {
                                Text(option.displayName)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                Field(label: "Model") {
                    selectField(modelLabel) {
                        ForEach(modelOptions) { option in
                            Toggle(isOn: Binding(
                                get: { modelID == option.id },
                                set: { if $0 { modelID = option.id } })) {
                                Text(option.label)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Field(label: "Trust", hint: "If nobody answers when it asks, the answer is no.") {
                selectField(trust.trustLabel, tone: trust == .auto ? palette.destructiveText : nil) {
                    ForEach(Autonomy.allCases, id: \.self) { level in
                        Toggle(isOn: Binding(
                            get: { trust == level },
                            set: { if $0 { trust = level } })) {
                            Text(level.trustLabel)
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
                    .bupsyField()
                Button {
                    typingNewSection = false
                    if !sections.contains(trimmedFolder) { folder = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.scaled(10), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Pick an existing section")
                .accessibilityLabel("Pick an existing section")
            }
        } else {
            selectField(trimmedFolder.isEmpty ? "Unassigned" : trimmedFolder) {
                ForEach(sections, id: \.self) { section in
                    Toggle(isOn: Binding(
                        get: { trimmedFolder == section },
                        set: { if $0 { folder = section } })) {
                        Text(section)
                    }
                }
                Toggle(isOn: Binding(
                    get: { trimmedFolder.isEmpty },
                    set: { if $0 { folder = "" } })) {
                    Text("Unassigned")
                }
                Divider()
                Button("New section…") {
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
        // A section whose "+" opened this may hold only pinned bots, which `folders` leaves out.
        if let initialSection, !initialSection.isEmpty, !list.contains(initialSection) {
            list.append(initialSection)
        }
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
        .frame(height: Theme.Size.controlMd)
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
            if let initialSection { folder = initialSection }
            // The first engine that is ready, so a new bot can actually run.
            engine = model.defaultNewBotEngine
            // A fresh bot starts on a shape nobody else wears, in any of the eight colours.
            shape = BotShape.allCases.first { !taken.contains($0) } ?? .bup
            colour = Int.random(in: BotShape.palette.indices)
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
                if bot.autonomy != trust { model.setAutonomy(bot, trust) }
            }
        }
        dismiss()
    }
}
