import BupsyKit
import SwiftUI

/// Routines for one bot: standing jobs on a schedule.
struct RoutinesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    @State private var isCreating = false

    init(bot: Bot) {
        self.bot = bot
    }

    private var routines: [Routine] {
        model.routines.filter { $0.botID == bot.id.rawValue }
    }

    var body: some View {
        SheetFrame(title: "\(bot.name)'s routines", icon: "clock.fill",
                   subtitle: "Jobs \(bot.name) does on a schedule, whether or not you are here.",
                   width: 560, tone: .info, primaryVerb: "close") {
            if routines.isEmpty {
                EmptyState(title: "No routines yet",
                           message: "A routine is a job \(bot.name) does on a schedule, like a "
                               + "morning briefing, a nightly check or a weekly summary.",
                           faceSize: 56)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.snug) {
                        ForEach(routines) { routine in
                            RoutineRow(routine: routine, bot: bot)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        } actions: {
            Button("New routine") { isCreating = true }
                .buttonStyle(QuietButton())
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
        }
        .sheet(isPresented: $isCreating) { NewRoutineSheet(bot: bot) }
    }
}

struct RoutineRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let routine: Routine
    let bot: Bot

    init(routine: Routine, bot: Bot) {
        self.routine = routine
        self.bot = bot
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.step) {
            Image(systemName: "clock.fill")
                .font(.system(size: Theme.scaled(13)))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 36, height: 36)
                .background(palette.background, in: .rect(cornerRadius: Theme.Radius.control))

            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name)
                    .font(Theme.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(palette.foreground)
                HStack(spacing: Theme.Space.tight) {
                    Text(Schedule.describe(routine.cron))
                    MetaDot()
                    // The tier's own words, so no view can quietly make a bigger claim than the
                    // tier actually delivers.
                    Text(routine.tier.shortLabel)
                        .foregroundStyle(routine.tier.survivesSleep ? palette.mutedForeground : palette.warning)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { routine.enabled },
                set: { model.setRoutineEnabled(routine, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Button {
                model.deleteRoutine(routine)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: Theme.scaled(12)))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Delete routine")
        }
        .padding(Theme.Space.step)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .opacity(routine.enabled ? 1 : 0.6)
        .help(routine.tier.promise)
    }
}

/// What the new-routine sheet makes. Folder watches live with the bot's own page.
enum RoutineSheetKind: Hashable {
    case routine
    case goal
}

/// The tabs across the top of the new-routine sheet: a routine or a standing goal.
struct RoutineKindPicker: View {
    @Binding var selection: RoutineSheetKind

    init(selection: Binding<RoutineSheetKind>) {
        _selection = selection
    }

    var body: some View {
        Picker("", selection: $selection) {
            Text("Routine").tag(RoutineSheetKind.routine)
            Text("Standing goal").tag(RoutineSheetKind.goal)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

struct NewRoutineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    /// The routine being edited, or nil to make a new one.
    var editing: Routine?

    @State private var kind = RoutineSheetKind.routine
    /// The bot it is for. Starts as the bot whose page this came from; nil means that one.
    @State private var botID: BotID?
    @State private var name = ""
    @State private var prompt = ""
    @State private var preset = Schedule.presets[0]
    @State private var tier = Routine.Tier.launchAgent

    init(bot: Bot, editing: Routine? = nil) {
        self.bot = bot
        self.editing = editing
    }

    /// The bot the routine will belong to.
    private var target: Bot {
        guard let botID else { return bot }
        return model.bots.first { $0.id == botID } ?? bot
    }

    var body: some View {
        if kind == .goal && editing == nil {
            NewObjectiveSheet(bot: target, onSwitchToRoutine: { kind = .routine })
        } else {
            form
        }
    }

    private var form: some View {
        SheetFrame(title: editing == nil ? "New routine" : "Edit routine", icon: "clock.fill",
                   subtitle: "A job a bot does on a schedule, like a nightly cleanup.",
                   width: 540, tone: .info, primaryVerb: "save") {
            if editing == nil {
                RoutineKindPicker(selection: $kind)
            }

            HStack(alignment: .top, spacing: Theme.Space.step) {
                Field(label: "Name") {
                    TextField("", text: $name, prompt: Text("Morning briefing"))
                        .textFieldStyle(BupsyFieldStyle())
                }
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
                    // An existing routine stays with its bot. Moving one is a delete and a new one.
                    .disabled(editing != nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 200)
            }

            Field(label: "What to do") {
                TextField("", text: $prompt, prompt: Text("Summarise what changed overnight"),
                          axis: .vertical)
                    .textFieldStyle(BupsyFieldStyle())
                    .lineLimit(3...5)
            }

            Field(label: "When") {
                Picker("", selection: $preset) {
                    ForEach(scheduleChoices, id: \.cron) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Each tier states its own limit. A routine that quietly does not run is the worst
            // failure this feature has, so the caveat is shown before it is created rather than
            // discovered afterwards.
            Field(label: "Runs", hint: tier.promise) {
                Picker("", selection: $tier) {
                    ForEach(availableTiers, id: \.self) { tier in
                        Text(tier.shortLabel).tag(tier)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            if tier == .machine && target.machineID == nil {
                Label("\(target.name) has no cloud machine yet, so this will fall back to "
                      + "running when bupsy is open.", systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button(editing == nil ? "Create routine" : "Save routine", action: commit)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear {
            guard let editing else { return }
            name = editing.name
            prompt = editing.prompt
            tier = editing.tier
            // A schedule that is not one of the presets keeps its own entry, so saving an edit
            // never quietly changes when it runs.
            preset = Schedule.presets.first { $0.cron == editing.cron }
                ?? Schedule.Preset(label: Schedule.describe(editing.cron), cron: editing.cron)
        }
        .onChange(of: botID) {
            // A different bot may not have a machine; never leave a tier it cannot honour picked.
            if !availableTiers.contains(tier) { tier = .launchAgent }
        }
    }

    private func commit() {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty, !cleanPrompt.isEmpty else { return }
        if let editing {
            model.updateRoutine(editing, name: cleanName, prompt: cleanPrompt,
                                cron: preset.cron, tier: tier)
        } else {
            model.addRoutine(to: target, name: cleanName, prompt: cleanPrompt,
                             cron: preset.cron, tier: tier)
        }
        dismiss()
    }

    /// The presets, plus the routine's own schedule when it is not one of them.
    private var scheduleChoices: [Schedule.Preset] {
        Schedule.presets.contains(preset) ? Schedule.presets : Schedule.presets + [preset]
    }

    /// Only offer a cloud machine when the bot has one; offering a choice that silently
    /// downgrades is worse than not offering it.
    private var availableTiers: [Routine.Tier] {
        target.machineID == nil ? [.appOpen, .launchAgent] : Routine.Tier.allCases
    }
}

/// Everyday schedules, in words. A cron field would be precise and almost nobody would use it.
enum Schedule {
    struct Preset: Hashable {
        let label: String
        let cron: String
    }

    static let presets: [Preset] = [
        Preset(label: "Every weekday at 7am", cron: "0 7 * * 1-5"),
        Preset(label: "Every weekday at 9am", cron: "0 9 * * 1-5"),
        Preset(label: "Every day at 8am", cron: "0 8 * * *"),
        Preset(label: "Every day at 6pm", cron: "0 18 * * *"),
        Preset(label: "Twice a day, 9am and 5pm", cron: "0 9,17 * * *"),
        Preset(label: "Every Monday at 9am", cron: "0 9 * * 1"),
        Preset(label: "Every hour", cron: "0 * * * *"),
    ]

    static func describe(_ cron: String) -> String {
        presets.first { $0.cron == cron }?.label ?? cron
    }
}
