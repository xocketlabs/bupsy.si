import BupsyKit
import SwiftUI

/// Standing goals for one bot.
struct ObjectivesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    @State private var isCreating = false

    init(bot: Bot) {
        self.bot = bot
    }

    private var objectives: [Objective] {
        model.objectives.filter { $0.botID == bot.id.rawValue }
    }

    var body: some View {
        SheetFrame(title: "\(bot.name)'s goals", icon: "target",
                   subtitle: "Things \(bot.name) keeps true, checked on a schedule.",
                   width: 600, tone: .info, primaryVerb: "close") {
            if objectives.isEmpty {
                EmptyState(title: "No standing goals",
                           message: "A goal is something \(bot.name) keeps true, rather than a job "
                               + "it does once. It checks on a schedule and acts only when something is off.",
                           faceSize: 56)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.snug) {
                        ForEach(objectives) { objective in
                            ObjectiveRow(objective: objective)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        } actions: {
            Button("New goal") { isCreating = true }
                .buttonStyle(QuietButton())
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
        }
        .sheet(isPresented: $isCreating) { NewObjectiveSheet(bot: bot) }
    }
}

struct ObjectiveRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let objective: Objective
    @State private var showsNotes = false

    init(objective: Objective) {
        self.objective = objective
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(alignment: .top, spacing: Theme.Space.step) {
                Image(systemName: "target")
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 36, height: 36)
                    .background(palette.background, in: .rect(cornerRadius: Theme.Radius.control))

                VStack(alignment: .leading, spacing: 3) {
                    Text(objective.goal)
                        .font(Theme.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(palette.foreground)
                    Text("Met when: \(objective.doneWhen)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                    HStack(spacing: Theme.Space.tight) {
                        if let outcome = objective.lastOutcome {
                            Text(outcome.label)
                                .foregroundStyle(outcome.needsAttention ? palette.warning : palette.success)
                        } else {
                            Text("Not checked yet").foregroundStyle(palette.mutedForeground)
                        }
                        MetaDot()
                        Text(Schedule.describe(objective.checkCron))
                            .foregroundStyle(palette.mutedForeground)
                    }
                    .font(Theme.Typography.caption)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { objective.enabled },
                    set: { model.setObjectiveEnabled(objective, $0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)

                Menu {
                    Button("Check now") { model.checkObjective(objective) }
                    Button(showsNotes ? "Hide what it's learned" : "What it's learned") {
                        showsNotes.toggle()
                    }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteObjective(objective) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: Theme.scaled(13), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if showsNotes {
                // Editable on purpose. These notes ride into every check, so the ability to read
                // and correct them is the real safeguard against a bot drifting on a wrong
                // assumption it taught itself.
                TextEditor(text: Binding(
                    get: { objective.notes },
                    set: { model.setObjectiveNotes(objective, $0) }
                ))
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.tight)
                .frame(height: 90)
                .background(palette.background, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(palette.border)
                }
                Text("The bot adds to this as it learns. Edit it if it has got something wrong.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
        }
        .padding(Theme.Space.step)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .opacity(objective.enabled ? 1 : 0.6)
    }
}

struct NewObjectiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    /// Set when this sheet is the "Standing goal" tab of the new-routine sheet: picking the
    /// Routine tab hands back to it. nil when it was opened on its own, and then it has no tabs.
    let onSwitchToRoutine: (() -> Void)?
    /// Set when this is one tab of the new-routine sheet: any other tab picked is handed back.
    /// Takes over from `onSwitchToRoutine` when both are given.
    let onSwitchKind: ((RoutineSheetKind) -> Void)?

    @State private var goal = ""
    @State private var doneWhen = ""
    @State private var preset = Schedule.objectivePresets[0]
    @State private var tier = Routine.Tier.launchAgent
    /// Always "Standing goal" here; choosing Routine hands back and resets it.
    @State private var kindTab = RoutineSheetKind.goal

    init(bot: Bot, onSwitchToRoutine: (() -> Void)? = nil,
         onSwitchKind: ((RoutineSheetKind) -> Void)? = nil) {
        self.bot = bot
        self.onSwitchToRoutine = onSwitchToRoutine
        self.onSwitchKind = onSwitchKind
    }

    var body: some View {
        SheetFrame(
            title: "New standing goal",
            icon: "target",
            subtitle: "Something \(bot.name) keeps true. It checks on a schedule and acts only "
                + "when it is not.",
            width: 540,
            tone: .info,
            primaryVerb: "save"
        ) {
            if onSwitchToRoutine != nil || onSwitchKind != nil {
                RoutineKindPicker(selection: $kindTab)
            }

            Field(label: "What should stay true?") {
                TextField("", text: $goal, prompt: Text("My inbox has nothing older than a day"))
                    .textFieldStyle(BupsyFieldStyle())
            }

            // A vague goal with a sharp done-when still works. The reverse does not.
            Field(label: "How will \(bot.name) know it's met?",
                  hint: "Be specific. It's what the bot measures against.") {
                TextField("", text: $doneWhen,
                          prompt: Text("No unread mail older than 24 hours remains"))
                    .textFieldStyle(BupsyFieldStyle())
            }

            Field(label: "Check") {
                Picker("", selection: $preset) {
                    ForEach(Schedule.objectivePresets, id: \.cron) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Field(label: "Runs", hint: tier.promise) {
                Picker("", selection: $tier) {
                    ForEach(availableTiers, id: \.self) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Save goal") {
                model.addObjective(
                    to: bot,
                    goal: goal.trimmingCharacters(in: .whitespaces),
                    doneWhen: doneWhen.trimmingCharacters(in: .whitespaces),
                    cron: preset.cron, tier: tier)
                dismiss()
            }
            .buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty
                      || doneWhen.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onChange(of: bot.id) {
            if !availableTiers.contains(tier) { tier = .launchAgent }
        }
        .onChange(of: kindTab) {
            guard kindTab != .goal else { return }
            let picked = kindTab
            kindTab = .goal
            if let onSwitchKind {
                onSwitchKind(picked)
            } else if picked == .routine {
                onSwitchToRoutine?()
            }
        }
    }

    private var availableTiers: [Routine.Tier] {
        bot.machineID == nil ? [.appOpen, .launchAgent] : Routine.Tier.allCases
    }
}

extension Schedule {
    /// Objectives check more often than routines run: most checks should find nothing to do and
    /// cost almost nothing, so frequent checking is the normal case rather than an extravagance.
    static let objectivePresets: [Preset] = [
        Preset(label: "Hourly on weekdays, 9am–6pm", cron: "0 9-18 * * 1-5"),
        Preset(label: "Every hour", cron: "0 * * * *"),
        Preset(label: "Three times a day", cron: "0 9,13,17 * * *"),
        Preset(label: "Once a day at 9am", cron: "0 9 * * *"),
        Preset(label: "Weekdays at 9am", cron: "0 9 * * 1-5"),
    ]
}
