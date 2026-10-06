import BupsyKit
import SwiftUI

/// One routine as a page: whether it is on, what it has done lately, when it runs next, and what
/// it tells the bot. Opened from a routine row on a bot's page or in the routines sheet.
struct RoutineDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let routine: Routine
    let bot: Bot
    /// Back to wherever this was opened from.
    let onClose: () -> Void

    @State private var editing: Routine?
    @State private var confirmsDelete = false
    /// Worked out off the main thread: a schedule that rarely matches can take a while to search.
    @State private var nextRun: Date?
    @State private var scheduleReadable = true
    /// The width the page's content has, measured, so the two panels can stack when narrow.
    @State private var contentWidth: CGFloat = 800

    /// Below this the schedule and "what it does" panels sit one above the other.
    private static let stackBelow: CGFloat = 640

    init(routine: Routine, bot: Bot, onClose: @escaping () -> Void) {
        self.routine = routine
        self.bot = bot
        self.onClose = onClose
    }

    private var isBusy: Bool { model.isRunning(bot.id) }

    /// The page's width on the board: wider than other pages, for the two panels side by side.
    private static let maxWidth: CGFloat = 896

    var body: some View {
        let runs = model.runs(of: routine)
        let stats = RoutineRunStats(runs: runs, cron: routine.cron)
        let stacked = contentWidth < Self.stackBelow
        let panels = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.gutter))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.gutter))
        // Schedule to "what it does" is 1 to 1.5, as on the board.
        let scheduleWidth = max(0, (contentWidth - Theme.Space.gutter) * 0.4)

        VStack(spacing: 0) {
            topbar
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                        header
                        if !routine.enabled { pausedBanner }
                    }
                    statTiles(stats)
                    panels {
                        if stacked {
                            schedulePanel
                                .frame(maxWidth: .infinity)
                        } else {
                            schedulePanel
                                .frame(width: scheduleWidth)
                        }
                        whatItDoesPanel
                            .frame(maxWidth: .infinity)
                    }
                    lastRuns(runs)
                }
                .frame(maxWidth: Self.maxWidth, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { contentWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in contentWidth = width }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, Theme.Space.section)
                .padding(.bottom, Theme.Space.page)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $editing) { NewRoutineSheet(bot: bot, editing: $0) }
        .confirmationDialog("Delete \(routine.name)?", isPresented: $confirmsDelete) {
            Button("Delete routine", role: .destructive) {
                let doomed = routine
                onClose()
                model.deleteRoutine(doomed)
            }
        } message: {
            Text("It stops running. What it already did stays in the thread.")
        }
        .task(id: scheduleKey) {
            let cron = routine.cron
            let found: (Bool, Date?) = await Task.detached { () -> (Bool, Date?) in
                guard let expression = try? CronExpression(cron) else { return (false, nil) }
                return (true, expression.nextFire(after: Date()))
            }.value
            scheduleReadable = found.0
            nextRun = found.1
        }
    }

    /// Recomputes the next run whenever the schedule changes or a slot is used up.
    private var scheduleKey: String {
        "\(routine.cron)|\(routine.lastFiredAt?.timeIntervalSince1970 ?? 0)|\(routine.enabled)"
    }

    // MARK: - Top

    private var topbar: some View {
        Topbar(trail: [bot.name, routine.name]) {
            Button(action: onClose) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(ThreadButtonStyle(kind: .ghost, height: Theme.Size.control))
            .keyboardShortcut(.cancelAction)
            .help("Back to \(bot.name) (Esc)")

            // Delete is rare and can't be undone, so it waits in a menu rather than beside Run now.
            Menu {
                Button("Delete routine…", role: .destructive) { confirmsDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: Theme.scaled(13), weight: .semibold))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for this routine")
            .accessibilityLabel("More for \(routine.name)")

            Button("Edit") { editing = routine }
                .buttonStyle(ThreadButtonStyle(kind: .secondary, height: Theme.Size.control))

            Button { model.runRoutineNow(routine) } label: {
                Label("Run now", systemImage: "play.fill")
            }
            .buttonStyle(ThreadButtonStyle(kind: .primary, height: Theme.Size.control))
            .disabled(isBusy)
            .help(isBusy ? "\(bot.name) is working on something. Try again when it's done."
                  : "Run it now. The next scheduled run still happens.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.gutter) {
            // Asleep while the routine is off, so the page says "paused" before you read a word.
            BotFace(bot: bot, mood: routine.enabled ? (isBusy ? .working : .idle) : .sleeping, size: 64)

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(routine.name)
                    .font(Theme.Typography.title)
                    .tracking(-0.4)
                    .foregroundStyle(palette.foreground)
                Text("\(bot.name)'s routine. \(routine.tier.promise)")
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Space.snug) {
                Text(routine.enabled ? "On" : "Paused")
                    .font(Theme.Typography.body)
                    .foregroundStyle(routine.enabled ? palette.foreground : palette.mutedForeground)
                Toggle("", isOn: Binding(
                    get: { routine.enabled },
                    set: { model.setRoutineEnabled(routine, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(palette.primary)
            }
            .padding(.top, 4)
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: Theme.Space.step) {
            Image(systemName: "pause.fill")
                .font(.system(size: Theme.scaled(11)))
                .foregroundStyle(palette.mutedForeground)
            // Honest about catch-up: the scheduler runs one missed slot, late, when it is resumed.
            Text("Paused. \(bot.name) skips this routine until you turn it back on. "
                 + "Then it runs once for any slot it missed and keeps to its schedule.")
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.step)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.base))
    }

    // MARK: - Numbers

    private func statTiles(_ stats: RoutineRunStats) -> some View {
        // Wraps onto more rows when there is no room for three across.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Space.step)],
                  alignment: .leading, spacing: Theme.Space.step) {
            RoutineStatTile(
                icon: "play.fill", label: "Runs this week",
                value: "\(stats.runsThisWeek)",
                note: stats.scheduledNote)
            RoutineStatTile(
                icon: "clock.fill", label: "Average time",
                value: stats.averageDuration.map { RoutineRunStats.durationLabel($0) } ?? "None yet",
                note: stats.timedRuns == 0 ? nil
                    : (stats.timedRuns == 1 ? "last run" : "last \(stats.timedRuns) runs"))
            RoutineStatTile(
                icon: "checkmark", label: "Last result",
                value: stats.latest.map { resultLabel($0) } ?? "Not run yet",
                note: stats.latest.map { latestNote($0) })
        }
    }

    private func latestNote(_ run: RunSummary) -> String {
        var note = Theme.stamp(run.startedAt)
        if let duration = run.duration { note += ", " + RoutineRunStats.durationLabel(duration) }
        return note
    }

    private func resultLabel(_ run: RunSummary) -> String {
        if run.succeeded { return "Done" }
        if run.status == "failed" { return "Failed" }
        if run.endedAt == nil { return isBusy ? "Running" : "Didn't finish" }
        return run.status.capitalized
    }

    private func resultTone(_ run: RunSummary) -> Color {
        if run.succeeded { return palette.success }
        if run.status == "failed" { return palette.destructiveText }
        if run.endedAt == nil && isBusy { return palette.infoText }
        return palette.warning
    }

    // MARK: - Panels

    private var schedulePanel: some View {
        RoutineDetailPanel(icon: "calendar", title: "Schedule", footer: scheduleFooter,
                           footerTone: scheduleFooterIsWarning ? palette.warning : nil) {
            VStack(spacing: Theme.Space.step) {
                scheduleRow(icon: "calendar", label: "When", value: Schedule.describe(routine.cron))
                scheduleRow(icon: "moon.fill", label: "Runs", value: routine.tier.shortLabel)
                scheduleRow(icon: routine.tier == .machine ? "server.rack" : "desktopcomputer",
                            label: "On", value: placeName)
            }
        }
    }

    private func scheduleRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(10)))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 14)
            Text(label)
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
            Spacer(minLength: Theme.Space.snug)
            Text(value)
                .font(Theme.Typography.label)
                .fontWeight(.medium)
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var placeName: String {
        guard routine.tier == .machine, let id = bot.machineID else { return "This Mac" }
        return model.machines.first { $0.id == id }?.name ?? "A cloud machine"
    }

    private var scheduleFooterIsWarning: Bool {
        !scheduleReadable || (routine.enabled && routine.tier == .launchAgent && model.routineProblem != nil)
    }

    private var scheduleFooter: String {
        if !scheduleReadable { return "This schedule can't be read, so it won't run." }
        if !routine.enabled { return "No runs while paused" }
        if routine.tier == .launchAgent, let problem = model.routineProblem {
            return "The background schedule couldn't be set up: \(problem)"
        }
        guard let nextRun else { return "Working out the next run" }
        var text = "Next run \(RoutineRunStats.nextLabel(nextRun))"
        if routine.tier == .appOpen { text += ", if Bupsy is open" }
        return text
    }

    private var whatItDoesPanel: some View {
        RoutineDetailPanel(icon: "doc.text.fill", title: "What it does", footer: engineLine,
                           footerTone: nil) {
            Text(routine.prompt)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var engineLine: String {
        var line = bot.engine.displayName
        if let modelName = bot.model, !modelName.isEmpty { line += ", \(modelName)" }
        return line + ". Sent to \(bot.name) as written, each time it runs."
    }

    // MARK: - History

    @ViewBuilder
    private func lastRuns(_ runs: [RunSummary]) -> some View {
        // The newest run, while the bot is still on it, is shown live at the top rather than as
        // a row that only says "Running".
        let live: RunSummary? = runs.first.flatMap { $0.endedAt == nil && isBusy ? $0 : nil }
        let shown = Array(runs.filter { $0.id != live?.id }.prefix(12))
        // The most recent failure says why and offers the obvious fix, wherever it is in the list.
        let failedID = shown.first { $0.status == "failed" }?.id

        VStack(alignment: .leading, spacing: Theme.Space.step) {
            SectionHeader(
                icon: "clock.fill",
                title: "Last runs",
                badge: nil,
                subtitle: "What happened each run, newest first"
            ) { EmptyView() }

            if let live {
                liveRow(live)
            }

            if runs.isEmpty {
                HStack(spacing: Theme.Space.step) {
                    BotFace(bot: bot, mood: .sleeping, size: 32)
                    Text(emptyRunsText)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.gutter)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            } else {
                VStack(spacing: Theme.Space.snug) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, run in
                        runRow(run)
                        if run.id == failedID {
                            failureCallout(run, isLatest: index == 0 && live == nil)
                        }
                    }
                }
            }
        }
    }

    /// The run under way: what the bot is doing now, and for how long.
    private func liveRow(_ run: RunSummary) -> some View {
        HStack(spacing: Theme.Space.step) {
            BotFace(bot: bot, mood: .working, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.liveStatus(for: bot))
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Started \(RoutineRunStats.whenLabel(run.startedAt)), running for "
                         + RoutineRunStats.durationLabel(max(0, context.date.timeIntervalSince(run.startedAt))))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.snug)
            RoutineStatusPill(text: "Running", tone: palette.infoText)
        }
        .padding(Theme.Space.step)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var emptyRunsText: String {
        guard routine.enabled, let nextRun else {
            return "No runs of this routine yet."
        }
        return "No runs of this routine yet. The first is \(RoutineRunStats.nextLabel(nextRun))."
    }

    private func runRow(_ run: RunSummary) -> some View {
        CardRow {
            IconTile(systemName: run.succeeded
                     ? "checkmark" : (run.status == "failed" ? "stop.fill"
                                      : (run.endedAt == nil && isBusy ? "ellipsis" : "info.circle")))
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                Text(RoutineRunStats.whenLabel(run.startedAt))
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                HStack(spacing: Theme.Space.snug) {
                    if let duration = run.duration {
                        Label(RoutineRunStats.durationLabel(duration), systemImage: "clock.fill")
                            .labelStyle(RoutineCompactLabelStyle())
                    }
                    if let line = firstLine(run.reply) {
                        if run.duration != nil { MetaDot() }
                        Text(line).lineLimit(1)
                    } else if run.toolCalls > 0 {
                        if run.duration != nil { MetaDot() }
                        Text(run.toolCalls == 1 ? "1 action" : "\(run.toolCalls) actions")
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
            }
        } trailing: {
            RoutineStatusPill(text: resultLabel(run), tone: resultTone(run))
        }
    }

    private func failureCallout(_ run: RunSummary, isLatest: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.step) {
            BotFace(bot: bot, mood: .failed, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(isLatest ? "The last run failed" : "This run failed")
                    .font(Theme.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(palette.foreground)
                Text(firstLine(run.reply) ?? "\(bot.name) stopped before saying why. The thread has the details.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.snug)
            Button("Run again") { model.runRoutineNow(routine) }
                .buttonStyle(ThreadButtonStyle(kind: .secondary, height: 32))
                .disabled(isBusy)
        }
        .padding(Theme.Space.step)
        .background(palette.background, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(palette.destructive.opacity(0.3))
        }
        .padding(.leading, Theme.Size.tile + Theme.Space.step)
    }

    private func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }
}

// MARK: - Pieces

/// One number with what it is above it and its context beside it.
private struct RoutineStatTile: View {
    @Environment(\.palette) private var palette
    let icon: String
    let label: String
    let value: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(11)))
                    .foregroundStyle(palette.foreground)
                Text(label)
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
            }
            HStack(alignment: .lastTextBaseline, spacing: Theme.Space.snug) {
                Text(value)
                    .font(.system(size: Theme.scaled(24), weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(palette.foreground)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: Theme.Space.tight)
                if let note {
                    Text(note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                }
            }
        }
        .padding(Theme.Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
    }
}

/// A titled panel: an inner sheet of content on a card lip, with a quiet line underneath.
private struct RoutineDetailPanel<Content: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let title: String
    let footer: String
    let footerTone: Color?
    let content: Content

    init(icon: String, title: String, footer: String, footerTone: Color?,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.footer = footer
        self.footerTone = footerTone
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(palette.foreground)
                Text(title)
                    .font(Theme.Typography.heading)
                    .foregroundStyle(palette.foreground)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(Theme.Space.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colorScheme == .dark ? palette.card : palette.background,
                                in: .rect(cornerRadius: Theme.Radius.base))
                    .padding(2)
                Text(footer)
                    .font(Theme.Typography.label)
                    .foregroundStyle(footerTone ?? palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.step + 2)
                    .padding(.vertical, Theme.Space.step)
            }
            .background(colorScheme == .dark ? palette.sidebar : palette.card,
                        in: .rect(cornerRadius: Theme.Radius.card))
        }
    }
}

/// "Done", "Failed": a dot and a word on a wash of the same tone.
private struct RoutineStatusPill: View {
    let text: String
    let tone: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone).frame(width: 5, height: 5)
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(tone)
        }
        .padding(.horizontal, Theme.Space.snug)
        .padding(.vertical, 5)
        .background(tone.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.control))
    }
}

/// An icon and a word close together, for a meta line.
private struct RoutineCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: Theme.scaled(9)))
            configuration.title
        }
    }
}
