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
                Text("\(bot.name)'s routines").font(.headline)
                Spacer()
                Button("New routine") { isCreating = true }
            }
            .padding(16)

            Divider()

            if routines.isEmpty {
                VStack(spacing: 6) {
                    Text("No routines yet").font(.callout)
                    Text("A routine is a job \(bot.name) does on a schedule — a morning briefing, "
                         + "a nightly check, a weekly summary.")
                        .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The tier's own words, so no view can quietly make a bigger claim than the
                // tier actually delivers.
                Text(routine.tier.promise)
                    .font(.caption2)
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

    @State private var name = ""
    @State private var prompt = ""
    @State private var preset = Schedule.presets[0]
    @State private var tier = Routine.Tier.launchAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New routine").font(.headline)

            TextField("Name", text: $name, prompt: Text("Morning briefing"))
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("What should \(bot.name) do?").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $prompt, prompt: Text("Summarise what changed overnight"),
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }

            Picker("When", selection: $preset) {
                ForEach(Schedule.presets, id: \.cron) { preset in
                    Text(preset.label).tag(preset)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Runs", selection: $tier) {
                    ForEach(availableTiers, id: \.self) { tier in
                        Text(tier.label).tag(tier)
                    }
                }
                // Each tier states its own limit. A routine that quietly does not run is the
                // worst failure this feature has, so the caveat is shown before it is created,
                // not discovered afterwards.
                Text(tier.promise)
                    .font(.caption)
                    .foregroundStyle(tier.survivesSleep ? Color.secondary : Color.orange)
            }

            if tier == .machine && bot.machineID == nil {
                Label("\(bot.name) has no cloud machine yet, so this will fall back to "
                      + "running when bupsy is open.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.addRoutine(
                        to: bot,
                        name: name.trimmingCharacters(in: .whitespaces),
                        prompt: prompt.trimmingCharacters(in: .whitespaces),
                        cron: preset.cron,
                        tier: tier)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
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
