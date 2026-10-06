import AppKit
import BupsyKit
import SwiftUI

/// First run, ending with the person's first bot.
///
/// Seven steps. The first three explain the two things that are not obvious and both load-bearing:
/// bupsy runs the agent CLIs *they* already pay for, under their own sign-in, and bots ask before
/// they act. The next three make a bot (a face, a trust level, a section), and the last one shows
/// what was chosen and hands over to it.
///
/// Nothing is created until the last step: the bot is made only by "Say hi" or "Connect apps
/// first", so going Back and forth, or quitting halfway, never leaves a half-made bot behind.
///
/// A split window: on the left a tinted, dotted stage where Bupsy acts out each step, on the
/// right a progress bar, the step itself and a footer with Back and one primary action.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var checking = false
    @State private var copiedCommand: String?
    @State private var loaded = false

    // The bot being made. Held here until the last step.
    @State private var name = ""
    @State private var shape = BotShape.blob
    @State private var colour = 0
    @State private var trust = Autonomy.allowlist
    /// The engine picked on the sign-in step, when more than one is ready. nil means "the first
    /// one that can run".
    @State private var pickedEngine: EngineID?
    /// The section picked from the tiles. Empty means unassigned.
    @State private var sectionPick = ""
    @State private var namingSection = false
    @State private var newSection = ""
    /// Set when the person jumped back from the summary to change one thing, so Continue takes
    /// them straight back to it rather than through every step after.
    @State private var fromSummary = false

    init() {}

    private let pages = 7
    private let stepNames = ["Hello", "How it works", "Sign-in", "Your first bot", "Trust", "Sections", "Ready"]

    private enum Step {
        static let hello = 0
        static let how = 1
        static let signIn = 2
        static let face = 3
        static let trust = 4
        static let section = 5
        static let ready = 6
    }

    /// The row of sleeping bots under Bupsy on the first step.
    private static let lineup: [(shape: BotShape, colour: Int)] = [
        (.bup, 1), (.cat, 2), (.bunny, 4), (.ghost, 3), (.bear, 6), (.pill, 5), (.horns, 7),
    ]

    /// Section names offered when the person has none of their own yet.
    private static let presetSections: [(title: String, icon: String, detail: String)] = [
        ("Work", "folder", "Jobs, repos, clients"),
        ("Personal", "house", "Inbox, errands, plans"),
        ("Engineering", "chevron.left.forwardslash.chevron.right", "Builds, reviews, CI"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            stage
                .frame(width: 400)
                .frame(maxHeight: .infinity)
            column
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, idealWidth: 900, maxWidth: 1040, minHeight: 540, idealHeight: 620, maxHeight: 700)
        .background(palette.popover)
        .interactiveDismissDisabled()
        .onAppear(perform: load)
    }

    // MARK: - The bot being made

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var shownName: String { trimmedName.isEmpty ? "Your bot" : trimmedName }
    private var nameTaken: Bool { model.isNameTaken(trimmedName) }
    private var safeColour: Int {
        let count = BotShape.palette.count
        return ((colour % count) + count) % count
    }
    private var botTint: Color { BotShape.palette[safeColour] }
    private var colourName: String {
        safeColour < BotShape.colourNames.count ? BotShape.colourNames[safeColour] : "Colour"
    }
    private var takenShapes: Set<BotShape> { Set(model.bots.map(\.effectiveShape)) }

    /// The colour of the first bot wearing each shape, for the dot on its tile.
    private var wearers: [BotShape: Color] {
        var result: [BotShape: Color] = [:]
        for bot in model.bots where result[bot.effectiveShape] == nil {
            result[bot.effectiveShape] = BotFace.colour(of: bot)
        }
        return result
    }

    private var engine: EngineID { model.onboardingEngine(preferring: pickedEngine) }

    /// The section the bot will be filed in, or nil for unassigned.
    private var chosenSection: String? {
        if namingSection {
            let typed = newSection.trimmingCharacters(in: .whitespaces)
            return typed.isEmpty ? nil : typed
        }
        return sectionPick.isEmpty ? nil : sectionPick
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        name = model.onboardingSuggestedName()
        // A first bot starts on a shape nobody else wears, so it stands out from the starters.
        shape = BotShape.allCases.first { !takenShapes.contains($0) } ?? .blob
        colour = 0
        sectionPick = sectionOptions.first?.title ?? ""
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            MascotStageBackground(tint: page >= Step.face ? botTint : palette.primary)
            MascotStageGlow(tint: page >= Step.face ? botTint : palette.primary, diameter: 380)
            if page == Step.ready {
                MascotStageConfetti()
            }
            Group {
                switch page {
                case Step.hello: helloScene
                case Step.how: howScene
                case Step.signIn: enginesScene
                case Step.face: faceScene
                case Step.trust: trustScene
                case Step.section: sectionScene
                default: readyScene
                }
            }
            .id(page)
            .transition(.opacity)
        }
        .clipped()
        .animation(.easeOut(duration: 0.2), value: safeColour)
    }

    /// Bupsy itself: the pink Bup.
    private func bupsy(_ mood: BotMood, size: CGFloat) -> some View {
        BotFace(hue: 0, mood: mood, size: size, shape: .bup, colour: 0)
    }

    /// The bot being made, as it looks right now.
    private func newBot(_ mood: BotMood, size: CGFloat) -> some View {
        BotFace(hue: 0.5, mood: mood, size: size, shape: shape, colour: safeColour)
    }

    private var helloScene: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            MascotStageBubble(text: "Hi! I'm Bupsy.")
                .padding(.bottom, 16)
            bupsy(.waitingForYou, size: 180)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.snug) {
                HStack(spacing: 4) {
                    ForEach(Array(Self.lineup.enumerated()), id: \.offset) { _, member in
                        BotFace(hue: 0, mood: .sleeping, size: 44, shape: member.shape, colour: member.colour)
                    }
                }
                Text("Your future team, asleep until you make them")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
            .padding(.bottom, 32)
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    /// The bots already on the roster, up to three, for the "how it works" diagram. The starter
    /// bots on a first launch; whatever is there if onboarding is shown again.
    private var trio: [(name: String, shape: BotShape, colour: Int)] {
        let visible = model.bots.filter { !$0.hidden }.prefix(3)
        if visible.isEmpty {
            return [(name: "Scout", shape: BotShape.bup, colour: 0),
                    (name: "Builder", shape: BotShape.cat, colour: 2),
                    (name: "Inbox", shape: BotShape.bear, colour: 6)]
        }
        return visible.map { bot -> (name: String, shape: BotShape, colour: Int) in
            (name: bot.name, shape: bot.effectiveShape,
             colour: bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue))
        }
    }

    private var howScene: some View {
        let line = palette.mutedForeground.opacity(0.6)
        return VStack(spacing: 0) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "key.fill")
                    .font(.system(size: Theme.scaled(12)))
                Text("Your Claude Code or Codex plan")
                    .font(.system(size: Theme.scaled(14), weight: .medium))
            }
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.popover, in: .rect(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
            MascotStageDash(tint: line, length: 26)
            bupsy(.idle, size: 116)
            MascotStageTag(text: "Bupsy, on this Mac", compact: true)
            MascotStageDash(tint: line, length: 22)
            HStack(alignment: .top, spacing: 22) {
                ForEach(Array(trio.enumerated()), id: \.offset) { index, member in
                    VStack(spacing: 4) {
                        BotFace(hue: 0.5, mood: index == 1 ? .working : .idle, size: 70,
                                shape: member.shape, colour: member.colour)
                        MascotStageTag(text: member.name,
                                       dot: BotShape.palette[member.colour % BotShape.palette.count],
                                       compact: true)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private var enginesScene: some View {
        let left = EngineID.supported.first ?? .claude
        let right = EngineID.supported.last ?? .codex
        return VStack(spacing: 18) {
            MascotStageBubble(text: engineLine)
                .frame(maxWidth: 270)
            HStack(spacing: 0) {
                stageEngineCard(left)
                stageConnector(left)
                bupsy(engineMood, size: 140)
                stageConnector(right)
                stageEngineCard(right)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private func stageEngineCard(_ engine: EngineID) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: Theme.scaled(12), weight: .semibold))
            Text(engine.displayName)
                .font(Theme.Typography.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(palette.foreground)
        .frame(width: 86, height: 70)
        .background(palette.popover, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(engineTone(engine))
                .frame(width: 7, height: 7)
                .padding(8)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
    }

    private func stageConnector(_ engine: EngineID) -> some View {
        MascotStageDash(tint: engineTone(engine), length: 22, vertical: false)
    }

    /// Bupsy presenting the new bot, which stands on a lit spot of its own.
    private var faceScene: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 14) {
                MascotStageBubble(text: faceLine)
                    .frame(maxWidth: 170)
                bupsy(trimmedName.isEmpty ? .waitingForYou : .idle, size: 92)
            }
            .padding(.bottom, 52)
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    MascotStageSpot(tint: botTint, width: 210)
                        .offset(y: 14)
                    newBot(faceMood, size: 190)
                }
                MascotStageTag(text: shownName, dot: botTint)
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: shape)
    }

    private var faceLine: String {
        if trimmedName.isEmpty { return "Give it a name?" }
        if nameTaken { return "Another bot has that name." }
        return "A \(shape.label.lowercased()) called \(trimmedName)!"
    }

    private var faceMood: BotMood {
        if trimmedName.isEmpty { return .sleeping }
        if nameTaken { return .failed }
        return .idle
    }

    /// The new bot reacting to the trust level, with the Careful to Bold meter under it.
    private var trustScene: some View {
        VStack(spacing: 18) {
            MascotStageBubble(text: trustLine(trust))
                .frame(maxWidth: 300)
            newBot(trustMood(trust), size: 170)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(Autonomy.allCases, id: \.self) { level in
                        Capsule()
                            .fill(level <= trust ? meterFill : palette.foreground.opacity(0.12))
                            .frame(width: 40, height: 6)
                    }
                }
                HStack {
                    Text("Careful")
                    Spacer(minLength: 0)
                    Text("Bold")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
            }
            .frame(width: 178)
            .animation(.easeOut(duration: 0.18), value: trust)
        }
    }

    private var meterFill: Color { trust == .auto ? palette.destructive : botTint }

    /// The sidebar as it will look, with the new bot in its section and peeking over the top.
    private var sectionScene: some View {
        VStack(spacing: Theme.Space.step) {
            VStack(alignment: .leading, spacing: 0) {
                MascotStagePeek(shape: shape, colour: safeColour, size: 66)
                    .padding(.leading, 30)
                sidebarPreview
            }
            Text("Your sidebar, as it will look")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private struct PreviewSection {
        let title: String
        let names: [(name: String, shape: BotShape, colour: Int, isNew: Bool)]
        let more: Int
    }

    /// Up to four sections: the named ones on offer, then Unassigned, each with the bots already
    /// filed there and the new bot in the one chosen.
    private var previewSections: [PreviewSection] {
        var titles = sectionOptions.map(\.title)
        if let chosen = chosenSection, !titles.contains(chosen) { titles.insert(chosen, at: 0) }
        var picked = Array(titles.prefix(3))
        if let chosen = chosenSection, !picked.contains(chosen), !picked.isEmpty {
            picked[picked.count - 1] = chosen
        }
        var sections: [PreviewSection] = []
        for title in picked {
            sections.append(previewSection(title, existing: model.bots(in: title), holdsNew: chosenSection == title))
        }
        sections.append(previewSection("Unassigned", existing: model.ungroupedBots, holdsNew: chosenSection == nil))
        return sections
    }

    private func previewSection(_ title: String, existing: [Bot], holdsNew: Bool) -> PreviewSection {
        var names: [(name: String, shape: BotShape, colour: Int, isNew: Bool)] = []
        if holdsNew { names.append((name: shownName, shape: shape, colour: safeColour, isNew: true)) }
        for bot in existing {
            names.append((name: bot.name, shape: bot.effectiveShape,
                          colour: bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue),
                          isNew: false))
        }
        let shown = Array(names.prefix(2))
        return PreviewSection(title: title, names: shown, more: names.count - shown.count)
    }

    private var sidebarPreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.snug) {
                bupsy(.idle, size: 22)
                Text("Bupsy")
                    .font(.system(size: Theme.scaled(15), weight: .semibold))
                    .foregroundStyle(palette.foreground)
                Spacer(minLength: 0)
                Image(systemName: "magnifyingglass")
                Image(systemName: "plus")
            }
            .font(.system(size: Theme.scaled(12)))
            .foregroundStyle(palette.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            previewRow(icon: "hand.raised", "Waiting on you")
            previewRow(icon: "person.2", "Team")
            ForEach(Array(previewSections.enumerated()), id: \.offset) { _, section in
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Theme.scaled(8), weight: .bold))
                    Text(section.title.uppercased())
                        .font(.system(size: Theme.scaled(10), weight: .semibold))
                        .tracking(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                        .font(.system(size: Theme.scaled(10)))
                }
                .foregroundStyle(palette.mutedForeground)
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 4)
                if section.names.isEmpty {
                    Text("Nothing here yet")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                ForEach(Array(section.names.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: Theme.Space.snug) {
                        BotFace(hue: 0.5, mood: .idle, size: 20, shape: entry.shape, colour: entry.colour)
                        Text(entry.name)
                            .font(Theme.Typography.body)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(entry.isNew ? palette.cardHover : Color.clear,
                                in: .rect(cornerRadius: Theme.Radius.control))
                }
                if section.more > 0 {
                    Text("and \(section.more) more")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(10)
        .frame(width: 270, alignment: .topLeading)
        .frame(maxHeight: 430, alignment: .top)
        .background(palette.sidebar, in: .rect(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 3)
        .animation(.easeOut(duration: 0.18), value: chosenSection)
    }

    private func previewRow(icon: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(12)))
                .frame(width: 20)
            Text(text)
                .font(Theme.Typography.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.mutedForeground)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Both cheering, in the confetti.
    private var readyScene: some View {
        VStack(spacing: 6) {
            MascotStageBubble(text: "Let's go!")
                .padding(.bottom, 10)
            HStack(alignment: .bottom, spacing: 4) {
                bupsy(.done, size: 110)
                newBot(.done, size: 170)
            }
            MascotStageTag(text: shownName, dot: botTint)
                .padding(.top, 6)
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    // MARK: - Column

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress
            Spacer(minLength: Theme.Space.gutter)
            Group {
                switch page {
                case Step.hello: hello
                case Step.how: how
                case Step.signIn: engines
                case Step.face: face
                case Step.trust: safety
                case Step.section: sections
                default: ready
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(page)
            .transition(.opacity)
            Spacer(minLength: Theme.Space.gutter)
            footer
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .background(palette.popover)
    }

    /// One segment per step: done in ink, the current one in pink, the rest still empty.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { index in
                    Capsule()
                        .fill(index < page ? palette.foreground
                              : (index == page ? palette.primary : palette.cardHover))
                        .frame(height: 4)
                }
            }
            HStack(spacing: Theme.Space.snug) {
                Text(stepNames[min(page, stepNames.count - 1)])
                    .fontWeight(.medium)
                    .foregroundStyle(palette.foreground)
                Text("\(page + 1) of \(pages)")
                    .foregroundStyle(palette.mutedForeground)
            }
            .font(Theme.Typography.caption)
        }
        .animation(.easeOut(duration: 0.2), value: page)
    }

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            Text(title)
                .font(.system(size: Theme.scaled(28), weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(text)
                .font(.system(size: Theme.scaled(14)))
                .foregroundStyle(palette.mutedForeground)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hello: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            heading("Bots that use the AI you already pay for.",
                    "Bupsy turns your Claude Code or Codex subscription into a team of bots. Each one "
                        + "gets a face, a job and its own folder, and works while you do something else.")
            VStack(alignment: .leading, spacing: Theme.Space.step) {
                check("No account to make, nothing to buy")
                check("No servers of ours, no telemetry")
                check("Your sign-ins stay with the CLIs, in files you own")
            }
        }
    }

    private func check(_ text: String) -> some View {
        HStack(spacing: Theme.Space.step) {
            Image(systemName: "checkmark")
                .font(.system(size: Theme.scaled(12), weight: .bold))
                .foregroundStyle(palette.success)
                .frame(width: 18)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
        }
    }

    private var how: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            heading("Your subscription,\na team of bots.",
                    "Bupsy runs on this Mac and drives Claude Code or Codex for each bot, using your "
                        + "own sign-in. Nothing goes through a server of ours.")
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                fact("key.fill", "Your sign-in", "No account to make")
                fact("shield.fill", "Asks first", "You approve what runs")
                fact("folder.fill", "Own folder", "Each bot, its own space")
            }
        }
    }

    private func fact(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(13)))
                .foregroundStyle(palette.mutedForeground)
                .padding(.bottom, 4)
            Text(title)
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(palette.foreground)
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
    }

    private var engines: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            heading("What's signed in",
                    "Bots run under your own sign-in. One engine is enough to start.")
            VStack(spacing: Theme.Space.snug) {
                ForEach(EngineID.supported, id: \.self) { engine in
                    engineRow(engine)
                }
            }
            if readyEngines.count > 1 {
                Text("Your first bot runs on \(engine.displayName). Click the other to switch.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
            if let missing = firstMissingEngine {
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    Text("To add \(missing.displayName), run this once in Terminal and sign in")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                    commandBox(signInCommand(for: missing))
                }
            }
            if !isChecking && !readyEngines.isEmpty && readyEngines.count < EngineID.supported.count {
                HStack(spacing: Theme.Space.step) {
                    checkAgainButton
                    Text("Or skip it. You can add \(missingEngines.map(\.displayName).joined(separator: ", ")) any time.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            } else if !isChecking && readyEngines.isEmpty {
                HStack(spacing: Theme.Space.step) {
                    checkAgainButton
                    Text("Sign in to one, then check again. Or carry on and sign in later.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Every engine is listed from the start. Listing only the ones already checked left this
    /// page empty on first launch, while the check was still running. When more than one can
    /// run, the rows double as the choice of engine for the first bot.
    @ViewBuilder
    private func engineRow(_ engine: EngineID) -> some View {
        let choosable = readyEngines.count > 1 && readyEngines.contains(engine)
        if choosable {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { pickedEngine = engine }
            } label: {
                engineRowBody(engine, selected: engine == self.engine)
            }
            .buttonStyle(.plain)
        } else {
            engineRowBody(engine, selected: false)
        }
    }

    private func engineRowBody(_ engine: EngineID, selected: Bool) -> some View {
        let status = model.engineStatus[engine]
        return HStack(spacing: Theme.Space.step) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: Theme.scaled(12), weight: .medium))
                .foregroundStyle(palette.foreground)
                .frame(width: 40, height: 40)
                .background(palette.popover, in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.border))
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(palette.foreground)
                Text(engineDetail(status))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(2)
                    .help(engineDetail(status))
            }
            Spacer(minLength: Theme.Space.snug)
            statusPill(status)
        }
        .padding(Theme.Space.step)
        .background(selected ? palette.popover : palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(selected ? palette.foreground : Color.clear, lineWidth: 2)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func statusPill(_ status: AuthStatus?) -> some View {
        if let status {
            let tone = status.isUsable ? palette.success : palette.warning
            HStack(spacing: 5) {
                Circle().fill(tone).frame(width: 6, height: 6)
                Text(statusLabel(status))
            }
            .font(Theme.Typography.caption.weight(.medium))
            .foregroundStyle(tone)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 5)
            .background(tone.opacity(0.13), in: .rect(cornerRadius: Theme.Radius.control))
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking")
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
        }
    }

    private func commandBox(_ command: String) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Text(command)
                .font(.system(size: Theme.scaled(12), design: .monospaced))
                .foregroundStyle(palette.foreground)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedCommand = command
            } label: {
                Image(systemName: copiedCommand == command ? "checkmark" : "doc.on.doc")
                    .font(.system(size: Theme.scaled(12)))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.leading, Theme.Space.gutter)
        .padding(.trailing, Theme.Space.snug)
        .frame(height: 44)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border))
    }

    private var checkAgainButton: some View {
        Button(action: checkAgain) {
            HStack(spacing: 6) {
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "magnifyingglass")
                }
                Text("Check again")
            }
        }
        .buttonStyle(QuietButton(compact: true))
        .disabled(checking)
    }

    /// Name, shape and colour. The shape grid and swatches are the bot creator's own picker.
    private var face: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            heading("Make your first bot",
                    "A shape and a colour make it easy to spot. You can change both later.")
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
            AvatarPicker(shape: $shape, colour: $colour, taken: takenShapes, wearers: wearers)
        }
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            heading("How careful should \(shownName) be?",
                    "Bots ask before they act. If nobody answers, the answer is no.")
            VStack(spacing: Theme.Space.snug) {
                ForEach(Autonomy.allCases, id: \.self) { level in
                    trustRow(level)
                }
            }
            Text("You can change it any time: right-click \(shownName) and choose Trust, or open its panel.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trustRow(_ level: Autonomy) -> some View {
        let selected = level == trust
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { trust = level }
        } label: {
            HStack(spacing: Theme.Space.snug) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trustTitle(level))
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(level == .auto ? palette.destructiveText : palette.foreground)
                    Text(trustDetail(level))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
                Spacer(minLength: Theme.Space.snug)
                if level == .allowlist {
                    Text("Recommended")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.popover : palette.card,
                        in: .rect(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(selected ? palette.foreground : Color.clear, lineWidth: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Sections

    private struct SectionOption {
        let title: String
        let icon: String
        let detail: String
    }

    /// The person's own sections first (if onboarding is shown again), then the suggestions,
    /// five at most so the grid fits.
    private var sectionOptions: [SectionOption] {
        var options: [SectionOption] = []
        for folder in model.folders.prefix(3) {
            let count = model.bots(in: folder).count
            options.append(SectionOption(title: folder, icon: "folder",
                                         detail: count == 1 ? "1 bot" : "\(count) bots"))
        }
        for preset in Self.presetSections where !options.contains(where: {
            $0.title.compare(preset.title, options: .caseInsensitive) == .orderedSame
        }) {
            options.append(SectionOption(title: preset.title, icon: preset.icon, detail: preset.detail))
        }
        return Array(options.prefix(5))
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            heading("Where does \(shownName) live?",
                    "Sections keep a growing team tidy, like folders for bots. Make as many as you "
                        + "like and fold the ones you don't need.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.snug),
                                GridItem(.flexible(), spacing: Theme.Space.snug)],
                      alignment: .leading, spacing: Theme.Space.snug) {
                ForEach(sectionOptions, id: \.title) { option in
                    sectionTile(icon: option.icon, title: option.title, detail: option.detail,
                                selected: !namingSection && sectionPick == option.title) {
                        namingSection = false
                        sectionPick = option.title
                    }
                }
                sectionTile(icon: "tray", title: "Unassigned", detail: "Sort it out later",
                            selected: !namingSection && sectionPick.isEmpty) {
                    namingSection = false
                    sectionPick = ""
                }
                sectionTile(icon: "plus", title: "Name one", detail: "A section of your own",
                            selected: namingSection) {
                    namingSection = true
                }
            }
            if namingSection {
                Field(label: "Section name") {
                    TextField("", text: $newSection, prompt: Text("Research, Clients..."))
                        .textFieldStyle(BupsyFieldStyle())
                }
            }
        }
    }

    private func sectionTile(icon: String, title: String, detail: String, selected: Bool,
                             action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { action() }
        } label: {
            HStack(spacing: Theme.Space.step) {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Text(detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.popover : palette.card,
                        in: .rect(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(selected ? palette.foreground : Color.clear, lineWidth: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Ready

    private var ready: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            heading("\(shownName) is ready.",
                    "Say hi. It will ask what you want done first, then get to work. When it needs "
                        + "you, it waves.")
            VStack(spacing: 0) {
                recapRow("Face", "\(shape.label), \(colourName.lowercased())", step: Step.face, rule: true)
                recapRow("Engine", engineSummary, step: Step.signIn, rule: true)
                recapRow("Trust", trustTitle(trust), step: Step.trust, rule: true,
                         tone: trust == .auto ? palette.destructiveText : nil)
                recapRow("Section", chosenSection ?? "Unassigned", step: Step.section, rule: false)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 4)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            HStack(spacing: Theme.Space.snug) {
                Button { finish(openApps: false) } label: {
                    HStack(spacing: Theme.Space.snug) {
                        Image(systemName: "bubble.left.fill")
                        Text("Say hi to \(shownName)")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                Button { finish(openApps: true) } label: {
                    HStack(spacing: Theme.Space.snug) {
                        Image(systemName: "square.grid.2x2.fill")
                        Text("Connect apps first")
                    }
                }
                .buttonStyle(QuietButton())
            }
        }
    }

    private var engineSummary: String {
        let current = engine
        if model.engineStatus[current]?.isUsable == true { return current.displayName }
        return "\(current.displayName), sign in first"
    }

    private func recapRow(_ key: String, _ value: String, step: Int, rule: Bool,
                          tone: Color? = nil) -> some View {
        HStack(spacing: Theme.Space.step) {
            Text(key)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
            Spacer(minLength: Theme.Space.snug)
            Text(value)
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(tone ?? palette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Change") { jump(to: step) }
                .buttonStyle(.plain)
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
                .help("Go back and change the \(key.lowercased())")
        }
        .frame(height: 46)
        .overlay(alignment: .bottom) {
            if rule {
                Rectangle().fill(palette.border).frame(height: 1)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.step) {
            if page > 0 {
                Button("Back") { withAnimation(.easeOut(duration: 0.15)) { page -= 1 } }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, Theme.Space.gutter)
                    .frame(height: Theme.Size.control)
                    .contentShape(.rect)
            }
            Spacer(minLength: 0)
            // The last step's own buttons are the way out, so the footer only offers Back there.
            if page < Step.ready {
                HStack(spacing: 6) {
                    Text("press")
                    Keycap("Return")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                Button(action: next) {
                    HStack(spacing: Theme.Space.snug) {
                        Image(systemName: "arrow.right")
                        Text(nextLabel)
                    }
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
    }

    /// Whether the current step has what it needs to move on.
    private var canContinue: Bool {
        switch page {
        case Step.face:
            return !trimmedName.isEmpty && !nameTaken
        case Step.section:
            return !namingSection || !newSection.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            return true
        }
    }

    private var nextLabel: String {
        if fromSummary && page > Step.hello { return "Back to summary" }
        switch page {
        case Step.hello:
            return "Set me up"
        case Step.signIn:
            if readyEngines.count == 1, !isChecking, let only = readyEngines.first {
                return "Continue with \(only.displayName)"
            }
            return "Continue"
        default:
            return "Continue"
        }
    }

    private func next() {
        guard canContinue, page < Step.ready else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            if fromSummary && page > Step.hello {
                page = Step.ready
            } else {
                page += 1
            }
        }
        if page == Step.ready { fromSummary = false }
    }

    /// From the summary's Change links: go to that step, and come straight back after.
    private func jump(to step: Int) {
        fromSummary = true
        withAnimation(.easeOut(duration: 0.15)) { page = step }
    }

    /// Makes the bot for real, finishes onboarding and goes to it (or to Apps).
    private func finish(openApps: Bool) {
        let made = model.createOnboardingBot(name: trimmedName, engine: engine, shape: shape,
                                             colour: safeColour, trust: trust, section: chosenSection)
        guard made != nil else {
            // The name was taken after it was checked. Send them back to pick another.
            fromSummary = true
            withAnimation(.easeOut(duration: 0.15)) { page = Step.face }
            return
        }
        if openApps { model.openAppsAfterOnboarding() }
        dismiss()
    }

    private func checkAgain() {
        checking = true
        Task { @MainActor in
            await model.refreshEngineStatus()
            checking = false
        }
    }

    // MARK: - Engine status, in words

    private var isChecking: Bool { EngineID.supported.contains { model.engineStatus[$0] == nil } }

    private var readyEngines: [EngineID] { model.onboardingReadyEngines }

    private var missingEngines: [EngineID] {
        EngineID.supported.filter { engine in
            guard let status = model.engineStatus[engine] else { return false }
            return !status.isUsable
        }
    }

    private var firstMissingEngine: EngineID? { missingEngines.first }

    private var engineLine: String {
        if isChecking { return "Checking what's signed in..." }
        let ready = readyEngines.map(\.displayName).joined(separator: " and ")
        let missing = missingEngines.map(\.displayName).joined(separator: " and ")
        if missingEngines.isEmpty { return "Both engines found!" }
        if readyEngines.isEmpty { return "Nothing's signed in yet." }
        return "\(ready) is ready.\n\(missing) needs a sign-in."
    }

    private var engineMood: BotMood {
        if isChecking { return .working }
        if missingEngines.isEmpty { return .done }
        if readyEngines.isEmpty { return .waitingForYou }
        return .idle
    }

    private func engineTone(_ engine: EngineID) -> Color {
        guard let status = model.engineStatus[engine] else { return palette.mutedForeground }
        return status.isUsable ? palette.success : palette.warning
    }

    private func engineDetail(_ status: AuthStatus?) -> String {
        guard let status else { return "Looking for it on this Mac" }
        switch status {
        case .signedIn(let method):
            switch method {
            case .subscription: return "Signed in with your subscription"
            case .apiKey: return "Signed in with an API key"
            }
        case .signedInWithoutModelAccess(let detail):
            return detail.isEmpty ? "Signed in, but this plan can't run it" : detail
        case .signedOut:
            return "Not signed in yet"
        case .unknown(let message):
            return message.isEmpty ? "Couldn't check" : message
        }
    }

    private func statusLabel(_ status: AuthStatus) -> String {
        switch status {
        case .signedIn: "Ready"
        case .signedInWithoutModelAccess: "Can't run models"
        case .signedOut: "Not signed in"
        case .unknown: "Not ready"
        }
    }

    private func signInCommand(for engine: EngineID) -> String {
        switch engine {
        case .codex: "codex login"
        default: "claude"
        }
    }

    // MARK: - Trust, in words

    private func trustTitle(_ level: Autonomy) -> String {
        switch level {
        case .ask: "Asks before everything"
        case .allowlist: "Asks unless allowed"
        case .trusted: "Asks before leaving the Mac"
        case .auto: "Never asks"
        }
    }

    /// What each level really does, as AutonomyPolicy decides it.
    private func trustDetail(_ level: Autonomy) -> String {
        switch level {
        case .ask: "Even reading files"
        case .allowlist: "Reads freely, remembers what you always allow"
        case .trusted: "Asks before edits, commands and anything online"
        case .auto: "Runs anything on its own. Only for throwaway folders"
        }
    }

    private func trustLine(_ level: Autonomy) -> String {
        switch level {
        case .ask: "I'll ask before I even look."
        case .allowlist: "I'll ask once, then remember."
        case .trusted: "I'll stay on this Mac unless you say so."
        case .auto: "Wait. Never ask? Are you sure?"
        }
    }

    private func trustMood(_ level: Autonomy) -> BotMood {
        switch level {
        case .ask: .waitingForYou
        case .allowlist, .trusted: .idle
        case .auto: .failed
        }
    }
}
