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
    /// Set to ask before deleting. On the row, not in its menu, which is gone on click.
    @State private var deleting: Objective?

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
                        .lineLimit(3)
                        .help(objective.goal)
                    // A goal saved with no stop condition checks against itself; saying so twice
                    // adds nothing.
                    if !objective.doneWhen.isEmpty && objective.doneWhen != objective.goal {
                        Text("Met when: \(objective.doneWhen)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                    }
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

                ObjectiveToggle(objective: objective)

                ObjectiveMenu(objective: objective, showsNotes: $showsNotes,
                              onDelete: { deleting = objective })
            }

            if showsNotes {
                ObjectiveNotesEditor(objective: objective)
            }
        }
        .padding(Theme.Space.step)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .opacity(objective.enabled ? 1 : 0.6)
        .confirmsObjectiveDeletion($deleting) { model.deleteObjective($0) }
    }
}

// MARK: - Pieces shared with the bot page's Standing goals

/// On and off for a goal's scheduled checks, with a label a screen reader can say.
struct ObjectiveToggle: View {
    @Environment(AppModel.self) private var model
    let objective: Objective

    init(objective: Objective) {
        self.objective = objective
    }

    var body: some View {
        Toggle("Check \(objective.goal) automatically", isOn: Binding(
            get: { objective.enabled },
            set: { model.setObjectiveEnabled(objective, $0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(objective.enabled ? "Checked on its schedule. Turn off to pause." : "Paused. Turn on to check it on its schedule.")
    }
}

/// The "..." menu on a goal: check it now, read or correct what it has learned, delete it.
///
/// Delete only asks the view behind the menu to confirm. A menu closes on click, so the dialog
/// cannot live in it.
struct ObjectiveMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let objective: Objective
    @Binding var showsNotes: Bool
    let onDelete: () -> Void

    init(objective: Objective, showsNotes: Binding<Bool>, onDelete: @escaping () -> Void) {
        self.objective = objective
        self._showsNotes = showsNotes
        self.onDelete = onDelete
    }

    private var checking: Bool { model.isChecking(objective) }

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            // The check runs on its own and can take a while; this is what says it started.
            if checking {
                ProgressView()
                    .controlSize(.small)
                    .help("Checking now")
                    .accessibilityLabel("Checking \(objective.goal)")
            }
            menu
        }
    }

    private var menu: some View {
        Menu {
            Button(checking ? "Checking…" : "Check now") { model.checkObjective(objective) }
                .disabled(checking)
            Button(showsNotes ? "Hide what it's learned" : "Edit what it's learned") {
                showsNotes.toggle()
            }
            Divider()
            Button("Delete goal…", role: .destructive, action: onDelete)
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
        .help("Goal options")
        .accessibilityLabel("Options for \(objective.goal)")
    }
}

/// What a goal's bot has taught itself, open for reading and correcting.
struct ObjectiveNotesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let objective: Objective

    init(objective: Objective) {
        self.objective = objective
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
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
}

extension View {
    /// Asks before deleting a standing goal, in the same words wherever it is offered.
    func confirmsObjectiveDeletion(
        _ objective: Binding<Objective?>, perform: @escaping (Objective) -> Void
    ) -> some View {
        confirmsDeletion(
            of: objective,
            title: { "Delete the goal \u{201C}\($0.goal)\u{201D}?" },
            button: "Delete goal",
            message: { _ in
                "It stops being checked, and what the bot has learned about it is deleted too. This can't be undone."
            },
            perform: perform)
    }
}

/// The new-routine sheet opened on its Standing goal tab. Kept by this name, and with its old
/// arguments, for the places that ask for a new goal; the form itself lives in NewRoutineSheet so
/// there is one copy of it.
struct NewObjectiveSheet: View {
    let bot: Bot

    init(bot: Bot, onSwitchToRoutine: (() -> Void)? = nil,
         onSwitchKind: ((RoutineSheetKind) -> Void)? = nil) {
        self.bot = bot
    }

    var body: some View {
        NewRoutineSheet(bot: bot, kind: .goal)
    }
}
