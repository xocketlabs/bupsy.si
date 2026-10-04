import BupsyKit
import SwiftUI

/// Routines for one bot: standing jobs on a schedule.
struct RoutinesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    @State private var isCreating = false

    private var routines: [Routine] {
        model.routines.filter { $0.botID == bot.id.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(bot.name)'s routines").font(Theme.Typography.heading)
                Spacer()
                Button("New routine") { isCreating = true }
            }
            .padding(16)

            Divider()

            if routines.isEmpty {
                VStack(spacing: 6) {
                    Text("No routines yet").font(Theme.Typography.body)
                    Text("A routine is a job \(bot.name) does on a schedule — a morning briefing, "
                         + "a nightly check, a weekly summary.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                List {
                    ForEach(routines) { routine in
                        RoutineRow(routine: routine, bot: bot)
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
        .frame(width: 560, height: 420)
        .sheet(isPresented: $isCreating) { NewRoutineSheet(bot: bot) }
    }
}

struct RoutineRow: View {
    @Environment(AppModel.self) private var model
    let routine: Routine
    let bot: Bot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { routine.enabled },
                set: { model.setRoutineEnabled(routine, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name).fontWeight(.medium)
                Text(Schedule.describe(routine.cron))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                // The tier's own words, so no view can quietly make a bigger claim than the
                // tier actually delivers.
                Text(routine.tier.promise)
                    .font(Theme.Typography.badge)
                    .foregroundStyle(routine.tier.survivesSleep ? Color.secondary : Color.orange)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                model.deleteRoutine(routine)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .opacity(routine.enabled ? 1 : 0.5)
    }
}

struct NewRoutineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    /// The routine being edited, or nil to make a new one.
    var editing: Routine? = nil

    @State private var name = ""
    @State private var prompt = ""
    @State private var preset = Schedule.presets[0]
    @State private var tier = Routine.Tier.launchAgent

    var body: some View {
        SheetFrame(title: editing == nil ? "New routine" : "Edit routine", icon: "clock.arrow.circlepath",
                   subtitle: "A job \(bot.name) does on a schedule, whether or not you are here.") {
            Field(label: "Name") {
                TextField("", text: $name, prompt: Text("Morning briefing"))
                    .textFieldStyle(BupsyFieldStyle())
            }

            Field(label: "What should \(bot.name) do?") {
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
                        Text(tier.label).tag(tier)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if tier == .machine && bot.machineID == nil {
                Label("\(bot.name) has no cloud machine yet, so this will fall back to "
                      + "running when bupsy is open.", systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button(editing == nil ? "Create" : "Save") {
                let cleanName = name.trimmingCharacters(in: .whitespaces)
                let cleanPrompt = prompt.trimmingCharacters(in: .whitespaces)
                if let editing {
                    model.updateRoutine(editing, name: cleanName, prompt: cleanPrompt,
                                        cron: preset.cron, tier: tier)
                } else {
                    model.addRoutine(to: bot, name: cleanName, prompt: cleanPrompt,
                                     cron: preset.cron, tier: tier)
                }
                dismiss()
            }
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
    }

    /// The presets, plus the routine's own schedule when it is not one of them.
    private var scheduleChoices: [Schedule.Preset] {
        Schedule.presets.contains(preset) ? Schedule.presets : Schedule.presets + [preset]
    }

    /// Only offer a cloud machine when the bot has one; offering a choice that silently
    /// downgrades is worse than not offering it.
    private var availableTiers: [Routine.Tier] {
        bot.machineID == nil ? [.appOpen, .launchAgent] : Routine.Tier.allCases
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
