import BupsyKit
import SwiftUI

/// Standing goals for one bot.
struct ObjectivesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    @State private var isCreating = false

    private var objectives: [Objective] {
        model.objectives.filter { $0.botID == bot.id.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(bot.name)'s goals").font(Theme.Typography.heading)
                Spacer()
                Button("New goal") { isCreating = true }
            }
            .padding(16)

            Divider()

            if objectives.isEmpty {
                VStack(spacing: 6) {
                    Text("No standing goals").font(Theme.Typography.body)
                    Text("A goal is something \(bot.name) keeps true, rather than a job it does "
                         + "once. It checks on a schedule and acts only when something is off.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                List {
                    ForEach(objectives) { objective in
                        ObjectiveRow(objective: objective)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 460)
        .sheet(isPresented: $isCreating) { NewObjectiveSheet(bot: bot) }
    }
}

struct ObjectiveRow: View {
    @Environment(AppModel.self) private var model
    let objective: Objective
    @State private var showsNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { objective.enabled },
                    set: { model.setObjectiveEnabled(objective, $0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    Text(objective.goal).fontWeight(.medium)
                    Text("Met when: \(objective.doneWhen)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        if let outcome = objective.lastOutcome {
                            Text(outcome.label)
                                .foregroundStyle(outcome.needsAttention ? Color.orange : Color.green)
                        } else {
                            Text("Not checked yet").foregroundStyle(.secondary)
                        }
                        Text("· \(Schedule.describe(objective.checkCron))")
                            .foregroundStyle(.secondary)
                    }
                    .font(Theme.Typography.badge)
                }

                Spacer(minLength: 0)

                Menu {
                    Button("Check now") { model.checkObjective(objective) }
                    Button(showsNotes ? "Hide what it's learned" : "What it's learned") {
                        showsNotes.toggle()
                    }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteObjective(objective) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
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
                .frame(height: 90)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)
                }
                Text("The bot adds to this as it learns. Edit it if it has got something wrong.")
                    .font(Theme.Typography.badge).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(objective.enabled ? 1 : 0.5)
    }
}

struct NewObjectiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: Bot

    @State private var goal = ""
    @State private var doneWhen = ""
    @State private var preset = Schedule.objectivePresets[0]
    @State private var tier = Routine.Tier.launchAgent

    var body: some View {
        SheetFrame(
            title: "New standing goal",
            icon: "target",
            subtitle: "Not a job \(bot.name) does once — something it keeps true, and only acts "
                + "on when it is not.",
            width: 460
        ) {
            Field(label: "What should stay true?") {
                TextField("", text: $goal, prompt: Text("My inbox has nothing older than a day"))
                    .textFieldStyle(BupsyFieldStyle())
            }

            // A vague goal with a sharp done-when still works. The reverse does not.
            Field(label: "How will \(bot.name) know it's met?",
                  hint: "Be specific here — it's what the bot measures against.") {
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
                    ForEach(availableTiers, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Create") {
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
