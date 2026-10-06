import BupsyKit
import SwiftUI

/// What the new-routine sheet makes: a job on a schedule, a goal kept true, or a job that runs
/// when files in a folder change.
enum RoutineSheetKind: Hashable {
    case routine
    case goal
    case folderWatch
}

/// The tabs across the top of the new-routine sheet.
struct RoutineKindPicker: View {
    @Binding var selection: RoutineSheetKind

    init(selection: Binding<RoutineSheetKind>) {
        _selection = selection
    }

    var body: some View {
        Segmented(selection: $selection, options: [
            SegmentedOption(RoutineSheetKind.routine, "Routine"),
            SegmentedOption(RoutineSheetKind.goal, "Standing goal"),
            SegmentedOption(RoutineSheetKind.folderWatch, "Folder watch"),
        ], full: true)
        .frame(maxWidth: .infinity)
    }
}

/// The one sheet for making something a bot does on its own: a routine on a schedule, a standing
/// goal, or a folder watch, one tab each. It also edits a routine or a folder watch, without the
/// tabs.
///
/// Every tab's fields live here rather than in a sheet per tab, so what you typed on one tab is
/// still there when you come back to it.
struct NewRoutineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    /// The routine being edited, or nil to make something new.
    var editing: Routine?
    /// The folder watch being edited, or nil.
    var editingWatch: FolderWatch?

    @State private var kind: RoutineSheetKind
    /// The bot it is for. Starts as the bot whose page this came from; nil means that one.
    @State private var botID: BotID?

    // Routine
    @State private var name = ""
    @State private var prompt = ""
    @State private var preset = Schedule.presets[0]
    @State private var customTime = CronWords.Time(hour: 2, minute: 0)
    @State private var tier = Routine.Tier.launchAgent

    // Standing goal
    @State private var goal = ""
    @State private var stopWhen = ""
    @State private var checkEvery = Schedule.checkEvery[1]

    // Folder watch
    @State private var path = ""
    @State private var watchPrompt = ""
    @State private var fileTypes = ""

    @State private var loaded = false

    /// The Bot picker's width beside a wider field, 1.4 to 1 as on the board.
    private static let botWidth: CGFloat = 220

    /// `kind` picks the tab it opens on. An edit opens on its own kind, with no tabs.
    init(bot: Bot, editing: Routine? = nil, kind: RoutineSheetKind = .routine,
         editingWatch: FolderWatch? = nil) {
        self.bot = bot
        self.editing = editing
        self.editingWatch = editingWatch
        let start: RoutineSheetKind
        if editing != nil {
            start = .routine
        } else if editingWatch != nil {
            start = .folderWatch
        } else {
            start = kind
        }
        _kind = State(initialValue: start)
    }

    private var isEditing: Bool { editing != nil || editingWatch != nil }

    /// The bot it will belong to.
    private var target: Bot {
        guard let botID else { return bot }
        return model.bots.first { $0.id == botID } ?? bot
    }

    var body: some View {
        SheetFrame(title: title, icon: kind == .folderWatch && editingWatch != nil ? "folder.fill" : "clock.fill",
                   subtitle: subtitle, width: 600, tone: .info, primaryVerb: primaryVerb) {
            if !isEditing {
                RoutineKindPicker(selection: $kind)
            }
            switch kind {
            case .routine: routineFields
            case .goal: goalFields
            case .folderWatch: watchFields
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button(primaryLabel, action: commit)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
        }
        .onAppear(perform: load)
        .onChange(of: botID) {
            // A different bot may not have a machine; never leave a tier it cannot honour picked.
            if tier == .machine && target.machineID == nil { tier = .launchAgent }
        }
    }

    // MARK: - Words

    private var title: String {
        if editing != nil { return "Edit routine" }
        if editingWatch != nil { return "Edit folder watch" }
        return "New routine"
    }

    private var subtitle: String {
        switch kind {
        case .routine: "A job a bot does on a schedule, like a nightly cleanup."
        case .goal: "Something a bot keeps checking on until it is true."
        case .folderWatch: "A bot acts whenever files land in a folder."
        }
    }

    private var primaryLabel: String {
        switch kind {
        case .routine: "Save routine"
        case .goal: "Save goal"
        case .folderWatch: editingWatch == nil ? "Start watching" : "Save watch"
        }
    }

    private var primaryVerb: String {
        kind == .folderWatch && editingWatch == nil ? "start" : "save"
    }

    // MARK: - Routine

    @ViewBuilder
    private var routineFields: some View {
        HStack(alignment: .top, spacing: Theme.Space.step) {
            Field(label: "Name") {
                TextField("", text: $name, prompt: Text("Morning digest"))
                    .textFieldStyle(BupsyFieldStyle())
            }
            botField
                .frame(width: Self.botWidth)
        }

        Field(label: "What to do") {
            TextField("", text: $prompt, prompt: Text("Summarise what changed overnight"),
                      axis: .vertical)
                .textFieldStyle(BupsyFieldStyle())
                .lineLimit(3...5)
        }

        Field(label: "When") {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Picker("", selection: $preset) {
                    ForEach(scheduleChoices, id: \.cron) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if preset == Schedule.custom {
                    RoutineCustomTimeEditor(time: $customTime)
                }
            }
        }

        // Each tier states its own limit. A routine that quietly does not run is the worst
        // failure this feature has, so the caveat is shown before it is created rather than
        // discovered afterwards.
        Field(label: "Runs", hint: tier.promise) {
            RoutineTierPicker(selection: $tier, machineAvailable: target.machineID != nil,
                              machineHint: machineHint)
        }

        if tier == .machine && target.machineID == nil {
            Label("\(target.name) has no cloud machine yet, so this will fall back to "
                  + "running while Bupsy is open.", systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why "On a machine" can't be picked.
    private var machineHint: String {
        model.machines.isEmpty
            ? "Add a machine in Machines to use this."
            : "Put \(target.name) on a machine to use this."
    }

    /// The presets, the routine's own schedule when it is not one of them, then "Custom time".
    private var scheduleChoices: [Schedule.Preset] {
        let isOwn = !Schedule.presets.contains(preset) && preset != Schedule.custom
        let own: [Schedule.Preset] = isOwn ? [preset] : []
        return Schedule.presets + own + [Schedule.custom]
    }

    /// The cron the When field stands for.
    private var scheduleCron: String {
        preset == Schedule.custom ? CronWords.cron(for: customTime) : preset.cron
    }

    // MARK: - Standing goal

    @ViewBuilder
    private var goalFields: some View {
        Field(label: "Goal") {
            TextField("", text: $goal,
                      prompt: Text("Keep the main branch green. When CI fails, find the commit that broke it and open a fix."),
                      axis: .vertical)
                .textFieldStyle(BupsyFieldStyle())
                .lineLimit(3...5)
        }

        HStack(alignment: .top, spacing: Theme.Space.step) {
            botField
                .frame(maxWidth: .infinity)
            Field(label: "Check every") {
                Picker("", selection: $checkEvery) {
                    ForEach(Schedule.checkEvery, id: \.cron) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }

        Field(label: "Counts as met when", hint: "Optional. It keeps checking until you turn the goal off.") {
            TextField("", text: $stopWhen, prompt: Text("CI has passed three runs in a row"))
                .textFieldStyle(BupsyFieldStyle())
        }
    }

    // MARK: - Folder watch

    @ViewBuilder
    private var watchFields: some View {
        HStack(alignment: .top, spacing: Theme.Space.step) {
            Field(label: "Folder") {
                HStack(spacing: Theme.Space.snug) {
                    Text(path.isEmpty ? "No folder chosen"
                         : path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(path.isEmpty ? palette.mutedForeground : palette.foreground)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(path)
                    Button("Choose…", action: chooseFolder)
                        .buttonStyle(QuietButton(compact: true))
                }
            }
            botField
                .frame(width: Self.botWidth)
        }

        Field(label: "When a file arrives", hint: "It also gets the list of files that changed.") {
            TextField("", text: $watchPrompt,
                      prompt: Text("If it's an invoice, rename it to the date and vendor and move it to ~/Documents/Invoices."),
                      axis: .vertical)
                .textFieldStyle(BupsyFieldStyle())
                .lineLimit(3...5)
        }

        Field(label: "File types", hint: "Leave empty to watch every file.") {
            TextField("", text: $fileTypes, prompt: Text("pdf, png, jpg"))
                .textFieldStyle(BupsyFieldStyle())
        }

        Text("Runs while Bupsy is open. Changes \(target.name) makes itself don't set it off again.")
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    /// The watch's name: the folder's own.
    private var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Shared

    private var botField: some View {
        Field(label: "Bot") {
            Picker("", selection: Binding(
                get: { target.id },
                set: { botID = $0 }
            )) {
                ForEach(model.bots) { bot in
                    Text(bot.name).tag(bot.id)
                }
            }
            .labelsHidden()
            // An existing routine or watch stays with its bot. Moving one is a delete and a new one.
            .disabled(isEditing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCommit: Bool {
        switch kind {
        case .routine:
            !Self.clean(name).isEmpty && !Self.clean(prompt).isEmpty
        case .goal:
            !Self.clean(goal).isEmpty
        case .folderWatch:
            !path.isEmpty && !Self.clean(watchPrompt).isEmpty
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let editing {
            name = editing.name
            prompt = editing.prompt
            tier = editing.tier
            // A schedule that is not one of the presets opens as a custom time when it is one,
            // or keeps its own entry, so saving an edit never quietly changes when it runs.
            if let match = Schedule.presets.first(where: { $0.cron == editing.cron }) {
                preset = match
            } else if let time = CronWords.time(of: editing.cron) {
                preset = Schedule.custom
                customTime = time
            } else {
                preset = Schedule.Preset(label: Schedule.describe(editing.cron), cron: editing.cron)
            }
        }
        if let editingWatch {
            path = editingWatch.path
            watchPrompt = editingWatch.prompt
            fileTypes = editingWatch.fileTypes.joined(separator: ", ")
        }
    }

    private func commit() {
        guard canCommit else { return }
        switch kind {
        case .routine:
            if let editing {
                model.updateRoutine(editing, name: Self.clean(name), prompt: Self.clean(prompt),
                                    cron: scheduleCron, tier: tier)
            } else {
                model.addRoutine(to: target, name: Self.clean(name), prompt: Self.clean(prompt),
                                 cron: scheduleCron, tier: tier)
            }
        case .goal:
            let cleanGoal = Self.clean(goal)
            let stop = Self.clean(stopWhen)
            // With no stop condition the goal itself is what the bot checks against.
            model.addObjective(to: target, goal: cleanGoal, doneWhen: stop.isEmpty ? cleanGoal : stop,
                               cron: checkEvery.cron, tier: .launchAgent)
        case .folderWatch:
            let types = FolderWatch.fileTypes(from: fileTypes)
            if let editingWatch {
                // A watch keeps its name unless it now watches a different folder.
                let newName = path == editingWatch.path ? editingWatch.name : folderName
                model.updateFolderWatch(editingWatch, name: newName, prompt: Self.clean(watchPrompt),
                                        path: path, fileTypes: types)
            } else {
                model.addFolderWatch(to: target, name: folderName, prompt: Self.clean(watchPrompt),
                                     path: path, fileTypes: types)
            }
        }
        dismiss()
    }
}

/// "Runs": all three tiers, always shown, so you can see what a machine would add even before
/// you have one. A tier this bot can't use is shown but can't be picked, with why underneath.
///
/// Drawn to match `Segmented` exactly rather than built on it, because `Segmented` has no way to
/// show an option that can't be picked, and hiding "On a machine" would hide what it offers.
struct RoutineTierPicker: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: Routine.Tier
    let machineAvailable: Bool
    let machineHint: String

    init(selection: Binding<Routine.Tier>, machineAvailable: Bool, machineHint: String) {
        _selection = selection
        self.machineAvailable = machineAvailable
        self.machineHint = machineHint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.hairline) {
                ForEach(Routine.Tier.allCases, id: \.self) { tier in
                    segment(tier)
                }
            }
            .padding(Theme.Space.hairline)
            .background(colorScheme == .dark ? palette.sidebar : palette.card,
                        in: .rect(cornerRadius: Theme.Radius.lg))

            if !machineAvailable {
                Text("On a machine: \(machineHint)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func segment(_ tier: Routine.Tier) -> some View {
        let usable = tier != .machine || machineAvailable
        let picked = selection == tier
        return Button {
            selection = tier
        } label: {
            Text(tier.shortLabel)
                .font(.system(size: Theme.scaled(13), weight: picked ? .medium : .regular))
                .foregroundStyle(picked ? palette.foreground : palette.mutedForeground)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.step)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.controlMd - 2 * Theme.Space.hairline)
                .background(picked ? (colorScheme == .dark ? palette.cardHover : palette.background) : Color.clear,
                            in: .rect(cornerRadius: Theme.Radius.md))
                .overlay {
                    if picked {
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(palette.border)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable ? 1 : 0.45)
        .help(usable ? tier.promise : machineHint)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(usable ? tier.promise : machineHint)
    }
}

/// "Custom time…": a time of day and the days it runs on, with the result in words underneath.
struct RoutineCustomTimeEditor: View {
    @Environment(\.palette) private var palette
    @Binding var time: CronWords.Time

    /// Monday first, as a week reads.
    private static let order = [1, 2, 3, 4, 5, 6, 0]
    private static let letters = ["S", "M", "T", "W", "T", "F", "S"]
    private static let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    init(time: Binding<CronWords.Time>) {
        _time = time
    }

    /// No days picked means every day, which shows as all seven picked.
    private var picked: Set<Int> { time.weekdays.isEmpty ? Set(0...6) : time.weekdays }

    private var clock: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date())
                    ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                time.hour = parts.hour ?? time.hour
                time.minute = parts.minute ?? time.minute
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.step) {
                DatePicker("Time", selection: clock, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
                HStack(spacing: Theme.Space.xs) {
                    ForEach(Self.order, id: \.self) { day in
                        dayButton(day)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(Schedule.describe(CronWords.cron(for: time)))
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
        }
    }

    private func dayButton(_ day: Int) -> some View {
        let on = picked.contains(day)
        return Button { toggle(day) } label: {
            Text(Self.letters[day])
                .font(Theme.Typography.caption)
                .fontWeight(.medium)
                .foregroundStyle(on ? palette.background : palette.mutedForeground)
                .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                .background(on ? palette.foreground : palette.secondary,
                            in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Self.names[day])
        .accessibilityLabel(Self.names[day])
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ day: Int) {
        var days = picked
        if days.contains(day) {
            // At least one day: a routine that never runs is not a schedule.
            guard days.count > 1 else { return }
            days.remove(day)
        } else {
            days.insert(day)
        }
        time.weekdays = days.count == 7 ? [] : days
    }
}

/// Everyday schedules, in words. A cron field would be precise and almost nobody would use it.
enum Schedule {
    struct Preset: Hashable {
        let label: String
        let cron: String
    }

    static let presets: [Preset] = [
        Preset(label: "Every night at 2am", cron: "0 2 * * *"),
        Preset(label: "Every morning at 8am", cron: "0 8 * * *"),
        Preset(label: "Weekdays at 9am", cron: "0 9 * * 1-5"),
        Preset(label: "Mondays at 9am", cron: "0 9 * * 1"),
        Preset(label: "Every hour", cron: "0 * * * *"),
    ]

    /// Not a schedule: the choice that opens the time and days editor.
    static let custom = Preset(label: "Custom time…", cron: "custom")

    /// How often a standing goal is checked. Most checks should find nothing to do and cost
    /// almost nothing, so frequent checking is the normal case rather than an extravagance.
    /// Lists rather than steps, which the scheduler deliberately does not read.
    static let checkEvery: [Preset] = [
        Preset(label: "15 minutes", cron: "0,15,30,45 * * * *"),
        Preset(label: "Hour", cron: "0 * * * *"),
        Preset(label: "4 hours", cron: "0 0,4,8,12,16,20 * * *"),
        Preset(label: "Day", cron: "0 9 * * *"),
    ]

    /// A preset's own words, else simple schedules in words, else the cron as written.
    static func describe(_ cron: String) -> String {
        presets.first { $0.cron == cron }?.label ?? CronWords.describe(cron) ?? cron
    }
}
