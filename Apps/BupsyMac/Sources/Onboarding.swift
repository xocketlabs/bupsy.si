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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @FocusState private var focusedField: OnboardingField?

    private enum OnboardingField: Hashable {
        case name
        case section
    }

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
        ("Work", "briefcase", "Jobs, repos, clients"),
        ("Personal", "house", "Inbox, errands, plans"),
        ("Engineering", "chevron.left.forwardslash.chevron.right", "Builds, reviews, CI"),
    ]

    var body: some View {
        // The board splits the window about in half. The stage keeps close to that share and the
        // column takes the rest, so the proportions hold at every size the sheet allows.
        GeometryReader { proxy in
            let stageWidth = min(max(proxy.size.width * 0.47, 380), 520)
            HStack(spacing: 0) {
                stage(scale: Self.stageScale(width: stageWidth, height: proxy.size.height))
                    .frame(width: stageWidth)
                    .frame(maxHeight: .infinity)
                column
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, idealWidth: 900, maxWidth: 1040, minHeight: 540, idealHeight: 620, maxHeight: 700)
        .background(palette.background)
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
        // A first bot starts on a shape nobody else wears, so it stands out from any bots already there.
        shape = BotShape.allCases.first { !takenShapes.contains($0) } ?? .blob
        colour = 0
        sectionPick = sectionOptions.first?.title ?? ""
    }

    // MARK: - Stage

    /// How big the cast is drawn, as a share of the Welcome board's sizes. The board is a
    /// 640 by 820 stage; the sheet's is smaller, so everything scales down only as far as the
    /// stage needs it to fit, and never below about two thirds.
    static func stageScale(width: CGFloat, height: CGFloat) -> CGFloat {
        let byHeight = (height - 40) / 700
        let byWidth = (width - 2 * Theme.Space.gutter) / 470
        return max(0.68, min(1, min(byHeight, byWidth)))
    }

    private func stage(scale s: CGFloat) -> some View {
        ZStack {
            MascotStageBackground(tint: page >= Step.face ? botTint : palette.primary)
            MascotStageGlow(tint: page >= Step.face ? botTint : palette.primary, diameter: 460 * s)
            if page == Step.ready {
                MascotStageConfetti()
            }
            // One element per scene for VoiceOver: what the scene shows, in words, rather than
            // every face in it read out one by one.
            ZStack {
                switch page {
                case Step.hello: helloScene(s)
                case Step.how: howScene(s)
                case Step.signIn: enginesScene(s)
                case Step.face: faceScene(s)
                case Step.trust: trustScene(s)
                case Step.section: sectionScene(s)
                default: readyScene(s)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(sceneLabel))
            .id(page)
            .transition(.opacity)
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: safeColour)
    }

    /// What each scene shows, for VoiceOver.
    private var sceneLabel: String {
        switch page {
        case Step.hello: return "Bupsy, waving hello, above a row of sleeping bots: your future team"
        case Step.how: return "Bupsy, on this Mac, running your bots with your Claude Code or Codex plan"
        case Step.signIn: return "Bupsy, checking sign-ins. " + engineLine.replacingOccurrences(of: "\n", with: " ")
        case Step.face: return "\(shownName), a \(colourName.lowercased()) \(shape.label.lowercased()). Bupsy says: \(faceLine)"
        case Step.trust: return "\(shownName) says: \(trustLine(trust))"
        case Step.section: return "Your sidebar, as it will look, with \(shownName) in \(chosenSection ?? "Unassigned")"
        default: return "Bupsy and \(shownName), cheering"
        }
    }

    /// Bupsy itself: the pink Bup.
    private func bupsy(_ mood: BotMood, size: CGFloat) -> some View {
        BotFace(hue: 0, mood: mood, size: size, shape: .bup, colour: 0)
    }

    /// The bot being made, as it looks right now.
    private func newBot(_ mood: BotMood, size: CGFloat) -> some View {
        BotFace(hue: 0.5, mood: mood, size: size, shape: shape, colour: safeColour)
    }

    private func helloScene(_ s: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            MascotStageBubble(text: "Hi! I'm Bupsy.")
                .padding(.bottom, Theme.Space.gutter)
            bupsy(.waitingForYou, size: 240 * s)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.snug) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(Array(Self.lineup.enumerated()), id: \.offset) { _, member in
                        BotFace(hue: 0, mood: .sleeping, size: 56 * s, shape: member.shape, colour: member.colour)
                    }
                }
                Text("Your future team, asleep until you make them")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
            }
            .padding(.bottom, Theme.Space.pageSide)
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    /// The bots already on the roster, up to three, for the "how it works" diagram. A first
    /// launch has none, so the board's example trio stands in; whatever is there if onboarding
    /// is shown again.
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

    private func howScene(_ s: CGFloat) -> some View {
        let line = palette.mutedForeground.opacity(0.6)
        return VStack(spacing: 0) {
            HStack(spacing: Theme.Space.compact) {
                Image(systemName: "key.fill")
                    .font(.system(size: Theme.scaled(14)))
                Text("Your Claude Code or Codex plan")
                    .font(.system(size: Theme.scaled(15), weight: .medium))
            }
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, Theme.Space.compact)
            .background(palette.background, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
            MascotStageDash(tint: line, length: 28 * s)
            // Working, as on the board: Bupsy is the one driving the bots below.
            bupsy(.working, size: 150 * s)
            MascotStageTag(text: "Bupsy, on this Mac", compact: true)
            MascotStageDash(tint: line, length: 28 * s)
            HStack(alignment: .top, spacing: 22 * s) {
                ForEach(Array(trio.enumerated()), id: \.offset) { index, member in
                    VStack(spacing: Theme.Space.xs) {
                        BotFace(hue: 0.5, mood: index == 1 ? .working : .idle, size: 88 * s,
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

    private func enginesScene(_ s: CGFloat) -> some View {
        let left = EngineID.supported.first ?? .claude
        // The two account engines on the stage; a local model is listed with them below.
        let right = EngineID.supported.dropFirst().first ?? .codex
        return VStack(spacing: 18) {
            MascotStageBubble(text: engineLine)
                .frame(maxWidth: 300)
            HStack(spacing: 0) {
                stageEngineCard(left, scale: s)
                stageConnector(left, scale: s)
                bupsy(engineMood, size: 150 * s)
                stageConnector(right, scale: s)
                stageEngineCard(right, scale: s)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private func stageEngineCard(_ engine: EngineID, scale s: CGFloat) -> some View {
        VStack(spacing: Theme.Space.snug) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: Theme.scaled(16), weight: .semibold))
            Text(engine.displayName)
                .font(.system(size: Theme.scaled(14), weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, Theme.Space.snug)
        .frame(width: 116 * s, height: 88 * s)
        .background(palette.background, in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(engineTone(engine))
                .frame(width: 7, height: 7)
                .padding(Theme.Space.snug)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
    }

    private func stageConnector(_ engine: EngineID, scale s: CGFloat) -> some View {
        MascotStageDash(tint: engineTone(engine), length: 40 * s, vertical: false)
    }

    /// Bupsy presenting the new bot, which stands on a lit spot of its own.
    private func faceScene(_ s: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Space.snug) {
            VStack(spacing: 14) {
                MascotStageBubble(text: faceLine, small: true)
                    .frame(maxWidth: 180 * s)
                bupsy(trimmedName.isEmpty ? .waitingForYou : .idle, size: 110 * s)
            }
            .padding(.bottom, 52 * s)
            VStack(spacing: Theme.Space.tight) {
                ZStack(alignment: .bottom) {
                    MascotStageSpot(tint: botTint, width: 210 * s)
                        .offset(y: 14)
                    newBot(faceMood, size: 240 * s)
                }
                MascotStageTag(text: shownName, dot: botTint)
                    .padding(.top, Theme.Space.compact)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: shape)
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
    private func trustScene(_ s: CGFloat) -> some View {
        VStack(spacing: 18) {
            MascotStageBubble(text: trustLine(trust))
                .frame(maxWidth: 300)
            newBot(trustMood(trust), size: 220 * s)
            VStack(spacing: Theme.Space.tight) {
                HStack(spacing: Theme.Space.tight) {
                    ForEach(Autonomy.allCases, id: \.self) { level in
                        Capsule()
                            .fill(level <= trust ? meterFill : palette.foreground.opacity(0.12))
                            .frame(width: 40, height: 8)
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: trust)
        }
    }

    private var meterFill: Color { trust == .auto ? palette.destructive : botTint }

    /// The sidebar as it will look, with the new bot in its section and peeking over the top.
    private func sectionScene(_ s: CGFloat) -> some View {
        VStack(spacing: Theme.Space.step) {
            VStack(alignment: .leading, spacing: 0) {
                MascotStagePeek(shape: shape, colour: safeColour, size: 84 * s)
                    .padding(.leading, 22)
                sidebarPreview(maxHeight: 440 * s)
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

    private func sidebarPreview(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
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
            .padding(.horizontal, Theme.Space.snug)
            .padding(.bottom, Theme.Space.snug)
            previewRow(icon: "hand.raised", "Waiting on you")
            previewRow(icon: "person.2", "Team")
            ForEach(Array(previewSections.enumerated()), id: \.offset) { _, section in
                HStack(spacing: Theme.Space.tight) {
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
                .padding(.horizontal, Theme.Space.snug)
                .padding(.top, Theme.Space.step)
                .padding(.bottom, Theme.Space.xs)
                if section.names.isEmpty {
                    Text("Nothing here yet")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.horizontal, Theme.Space.compact)
                        .padding(.vertical, Theme.Space.xs)
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
                    .padding(.horizontal, Theme.Space.snug)
                    .padding(.vertical, Theme.Space.xs)
                    .background(entry.isNew ? palette.cardHover : Color.clear,
                                in: .rect(cornerRadius: Theme.Radius.control))
                }
                if section.more > 0 {
                    Text("and \(section.more) more")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.horizontal, Theme.Space.compact)
                        .padding(.vertical, Theme.Space.hairline)
                }
            }
        }
        .padding(Theme.Space.compact)
        .frame(width: 270, alignment: .topLeading)
        .frame(maxHeight: maxHeight, alignment: .top)
        .background(palette.sidebar, in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 3)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: chosenSection)
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
        .padding(.horizontal, Theme.Space.snug)
        .padding(.vertical, Theme.Space.tight)
    }

    /// Both cheering, in the confetti.
    private func readyScene(_ s: CGFloat) -> some View {
        VStack(spacing: Theme.Space.tight) {
            MascotStageBubble(text: "Let's go!")
                .padding(.bottom, Theme.Space.compact)
            HStack(alignment: .bottom, spacing: Theme.Space.xs) {
                bupsy(.done, size: 140 * s)
                newBot(.done, size: 210 * s)
            }
            MascotStageTag(text: shownName, dot: botTint)
                .padding(.top, Theme.Space.tight)
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    // MARK: - Column

    /// Progress on top and the footer at the bottom stay put; the step between them scrolls
    /// when it is taller than the window, and sits centred when it is not.
    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress
                .padding(.horizontal, 44)
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    ZStack {
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
                    .padding(.horizontal, 44)
                    .padding(.vertical, Theme.Space.section)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            footer
                .padding(.horizontal, 44)
        }
        .padding(.top, 36)
        .padding(.bottom, 28)
        .background(palette.background)
    }

    /// One segment per step: done in ink, the current one in pink, the rest still empty.
    private var progress: some View {
        VStack(alignment: .leading, spacing: Theme.Space.compact) {
            HStack(spacing: Theme.Space.tight) {
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
            .font(Theme.Typography.label)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: page)
    }

    /// A step's title and line, at the Welcome board's sizes: 44 for the first and last steps,
    /// 36 for the two that explain, 32 for the ones with a form under them.
    private func heading(_ title: String, _ text: String, size: CGFloat = 32,
                         body: CGFloat = 16) -> some View {
        VStack(alignment: .leading, spacing: size >= 36 ? Theme.Space.gutter : Theme.Space.snug) {
            Text(title)
                .font(.system(size: Theme.scaled(size), weight: .semibold))
                .tracking(-size * (size >= 44 ? 0.035 : 0.03))
                .foregroundStyle(palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: Theme.scaled(body)))
                .foregroundStyle(palette.mutedForeground)
                .lineSpacing(body >= 17 ? 6 : 5)
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hello: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            heading("Bots that use the AI you already pay for.",
                    "Bupsy turns your Claude Code or Codex subscription into a team of bots. Each one "
                        + "gets a face, a job and its own folder, and works while you do something else.",
                    size: 44, body: 17)
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
                .font(.system(size: Theme.scaled(13), weight: .bold))
                .foregroundStyle(palette.success)
                .frame(width: 18)
            Text(text)
                .font(.system(size: Theme.scaled(15)))
                .foregroundStyle(palette.foreground)
        }
    }

    private var how: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            heading("Your subscription,\na team of bots.",
                    "Bupsy runs on this Mac and drives Claude Code or Codex for each bot, using your "
                        + "own sign-in. Nothing goes through a server of ours.",
                    size: 36, body: 17)
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                fact("key.fill", "Your sign-in", "No account to make")
                fact("shield.fill", "Asks first", "You approve what runs")
                fact("folder.fill", "Own folder", "Each bot, its own space")
            }
        }
    }

    private func fact(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(15)))
                .foregroundStyle(palette.mutedForeground)
                .padding(.bottom, Theme.Space.xs)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: Theme.scaled(14), weight: .medium))
                .foregroundStyle(palette.foreground)
            Text(detail)
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var engines: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            heading("What's signed in",
                    "Bots run under your own sign-in, or on a model on this Mac. One engine is enough to start.",
                    size: 36, body: 16)
            VStack(spacing: Theme.Space.step) {
                ForEach(EngineID.supported, id: \.self) { engine in
                    engineRow(engine)
                }
            }
            if readyEngines.count > 1 {
                Text("Your first bot runs on \(engine.displayName). Click \(readyEngines.count > 2 ? "another" : "the other") to switch.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
            }
            ForEach(missingEngines, id: \.self) { missing in
                if missing == .local {
                    localSetup
                } else {
                    accountSetup(missing)
                }
            }
            if !isChecking && !readyEngines.isEmpty && readyEngines.count < EngineID.supported.count {
                HStack(spacing: Theme.Space.step) {
                    checkAgainButton
                    Text("Or skip it. You can add \(missingEngines.map(\.displayName).joined(separator: ", ")) any time.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                }
            } else if !isChecking && readyEngines.isEmpty {
                HStack(spacing: Theme.Space.step) {
                    checkAgainButton
                    Text(missingEngines.allSatisfy { isNotInstalled($0) }
                         ? "Install one, then check again. Or carry on and set it up later."
                         : "Sign in to one, then check again. Or carry on and sign in later.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// How to add an engine that runs on an account: install it, or sign in.
    private func accountSetup(_ missing: EngineID) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if isNotInstalled(missing) {
                Text("To add \(missing.displayName), install it in Terminal, then sign in with \(AppModel.signInCommand(for: missing))")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                commandBox(AppModel.installCommand(for: missing))
            } else {
                Text("To add \(missing.displayName), run this once in Terminal and sign in")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                commandBox(AppModel.signInCommand(for: missing))
            }
        }
    }

    /// How to add a local model: Codex first, then Ollama or LM Studio with a model in it. Shown
    /// as commands to copy; Bupsy runs neither, since a model is a download of several gigabytes.
    private var localSetup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if isNotInstalled(.local) {
                Text("Local model runs through Codex. To add it, install Codex, then Ollama or LM Studio with a model")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                commandBox(AppModel.installCommand(for: .local))
            } else {
                Text("To add Local model, install Ollama (ollama.com) or LM Studio (lmstudio.ai), start it and get a model")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                commandBox(AppModel.signInCommand(for: .local))
            }
            Text(AppModel.localModelAdvice)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every engine is listed from the start. Listing only the ones already checked left this
    /// page empty on first launch, while the check was still running. When more than one can
    /// run, the rows double as the choice of engine for the first bot.
    @ViewBuilder
    private func engineRow(_ engine: EngineID) -> some View {
        let choosable = readyEngines.count > 1 && readyEngines.contains(engine)
        if choosable {
            let selected = engine == self.engine
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { pickedEngine = engine }
            } label: {
                engineRowBody(engine, selected: selected)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint("Your first bot runs on the selected engine")
        } else {
            engineRowBody(engine, selected: false)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(readyEngines.count == 1 && readyEngines.first == engine ? .isSelected : [])
        }
    }

    /// The row says what is true in plain words, from the same line Settings uses, plus where the
    /// CLI was found. Anything the CLI printed when the check failed goes in the tooltip only.
    private func engineRowBody(_ engine: EngineID, selected: Bool) -> some View {
        let status = model.engineStatus[engine]
        let path = model.engineBinaryPaths[engine]
        return HStack(spacing: Theme.Space.step) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: Theme.scaled(13), weight: .medium))
                .foregroundStyle(palette.foreground)
                .frame(width: 40, height: 40)
                .background(palette.background, in: .rect(cornerRadius: Theme.Radius.base))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.base).strokeBorder(palette.border))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(engine.displayName)
                    .font(.system(size: Theme.scaled(15), weight: .medium))
                    .foregroundStyle(palette.foreground)
                Text(status == nil ? "Looking for it on this Mac" : AppModel.accountStatusLine(status, path: path))
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .help(AppModel.engineStatusHelp(status, path: path))
            Spacer(minLength: Theme.Space.snug)
            statusPill(status)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.step)
        .background(selected ? palette.background : palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.bubble)
                .strokeBorder(selected ? palette.foreground : Color.clear, lineWidth: 2)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func statusPill(_ status: AuthStatus?) -> some View {
        if let status {
            Badge(text: statusLabel(status),
                  tone: status.isUsable ? BadgeTone.success : BadgeTone.warning,
                  dot: true)
        } else {
            HStack(spacing: Theme.Space.tight) {
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
                    .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(copiedCommand == command ? "Copied" : "Copy")
            .accessibilityLabel(copiedCommand == command ? "Copied" : "Copy \(command)")
        }
        .padding(.leading, Theme.Space.gutter)
        .padding(.trailing, Theme.Space.snug)
        .frame(minHeight: Theme.Size.controlLg)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border))
    }

    private var checkAgainButton: some View {
        Button(action: checkAgain) {
            HStack(spacing: Theme.Space.tight) {
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
                    "A shape and a colour make it easy to spot. You can change both later.",
                    size: 32, body: 15)
            Field(label: "Name") {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    TextField("", text: $name, prompt: Text("Give it a name"))
                        .bupsyField()
                        .focused($focusedField, equals: .name)
                        .onAppear { focusSoon(.name) }
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
                    "Bots ask before they act. If nobody answers, the answer is no.",
                    size: 32, body: 16)
            VStack(spacing: Theme.Space.snug) {
                ForEach(Autonomy.allCases, id: \.self) { level in
                    trustRow(level)
                }
            }
            Text("You can change it any time: right-click \(shownName) and choose Trust, or open its panel.")
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trustRow(_ level: Autonomy) -> some View {
        let selected = level == trust
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { trust = level }
        } label: {
            HStack(spacing: Theme.Space.snug) {
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(level.trustLabel)
                        .font(.system(size: Theme.scaled(15), weight: .medium))
                        .foregroundStyle(level == .auto ? palette.destructiveText : palette.foreground)
                    Text(trustDetail(level))
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.snug)
                if level == .allowlist {
                    Text("Recommended")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, Theme.Space.step)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.background : palette.card,
                        in: .rect(cornerRadius: Theme.Radius.bubble))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.bubble)
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
            options.append(SectionOption(title: folder, icon: "rectangle.stack",
                                         detail: count == 0 ? "No bots yet"
                                             : count == 1 ? "1 bot" : "\(count) bots"))
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
                        + "like and fold the ones you don't need.",
                    size: 32, body: 16)
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
                    focusSoon(.section)
                }
            }
            if namingSection {
                Field(label: "Section name") {
                    TextField("", text: $newSection, prompt: Text("Research, Clients…"))
                        .bupsyField()
                        .focused($focusedField, equals: .section)
                        .onAppear { focusSoon(.section) }
                }
            }
        }
    }

    private func sectionTile(icon: String, title: String, detail: String, selected: Bool,
                             action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { action() }
        } label: {
            HStack(spacing: Theme.Space.step) {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(14)))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(title)
                        .font(.system(size: Theme.scaled(15), weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Text(detail)
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.background : palette.card,
                        in: .rect(cornerRadius: Theme.Radius.bubble))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.bubble)
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
                        + "you, it waves.",
                    size: 44, body: 17)
            VStack(spacing: 0) {
                recapRow("Face", "\(shape.label), \(colourName.lowercased())", step: Step.face, rule: true)
                recapRow("Engine", engineSummary, step: Step.signIn, rule: true)
                recapRow("Trust", trust.trustLabel, step: Step.trust, rule: true,
                         tone: trust == .auto ? palette.destructiveText : nil)
                recapRow("Section", chosenSection ?? "Unassigned", step: Step.section, rule: false)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, Theme.Space.xs)
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
        if isNotInstalled(current) { return "\(current.displayName), install it first" }
        if current == .local { return "\(current.displayName), set it up first" }
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
            OnboardingChangeButton(key: key) { jump(to: step) }
        }
        .frame(minHeight: 46)
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
                Button("Back") { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { page -= 1 } }
                    .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .lg))
            }
            Spacer(minLength: 0)
            // The last step's own buttons are the way out, so the footer only offers Back there.
            if page < Step.ready {
                // Only offered when Return would actually do something.
                if canContinue {
                    HStack(spacing: Theme.Space.tight) {
                        Text("press")
                        Keycap("Return")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .accessibilityHidden(true)
                }
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
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
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
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { page = step }
    }

    /// Makes the bot for real, finishes onboarding and goes to it (or to Apps).
    ///
    /// "Say hi" keeps the step's promise: the bot greets the person and asks what it is for,
    /// the same first words a bot made any other way gets.
    private func finish(openApps: Bool) {
        let made = model.createOnboardingBot(name: trimmedName, engine: engine, shape: shape,
                                             colour: safeColour, trust: trust, section: chosenSection)
        guard let made else {
            // The name was taken after it was checked. Send them back to pick another.
            fromSummary = true
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { page = Step.face }
            return
        }
        if openApps {
            model.openAppsAfterOnboarding()
        } else if let bot = model.bots.first(where: { $0.id == made }) {
            model.greet(bot)
        }
        dismiss()
    }

    /// Moves focus to a field once it is on screen. Set a moment later, because a field that is
    /// still appearing ignores focus set in the same pass.
    private func focusSoon(_ field: OnboardingField) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            focusedField = field
        }
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

    /// True when the engine's CLI is not on this Mac at all, as opposed to signed out.
    private func isNotInstalled(_ engine: EngineID) -> Bool {
        if case .notInstalled? = model.engineStatus[engine] { return true }
        return false
    }

    private var engineLine: String {
        if isChecking { return "Checking what's signed in…" }
        if missingEngines.isEmpty { return "Every engine found!" }
        if readyEngines.isEmpty {
            return missingEngines.allSatisfy { isNotInstalled($0) } ? "None is installed yet." : "Nothing's ready yet."
        }
        let ready = readyEngines.map(\.displayName).joined(separator: " and ")
        let missing = missingEngines.map { engine -> String in
            if isNotInstalled(engine) { return "\(engine.displayName) isn't installed." }
            return engine == .local ? "\(engine.displayName) isn't set up." : "\(engine.displayName) needs a sign-in."
        }
        return "\(ready) \(readyEngines.count > 1 ? "are" : "is") ready.\n" + missing.joined(separator: "\n")
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

    private func statusLabel(_ status: AuthStatus) -> String {
        switch status {
        case .signedIn: "Ready"
        case .signedInWithoutModelAccess: "Can't run models"
        case .signedOut: "Not signed in"
        case .notInstalled: "Not installed"
        case .notReady: "Not set up"
        case .unknown: "Not ready"
        }
    }

    // MARK: - Trust, in words
    //
    // The titles are `Autonomy.trustLabel`, the same words every other screen uses.

    /// What each level really does, as AutonomyPolicy decides it.
    private func trustDetail(_ level: Autonomy) -> String {
        switch level {
        case .ask: "Even reading files"
        case .allowlist: "Reads freely, remembers what you always allow"
        case .trusted: "Reads freely. Edits, commands and apps wait for you"
        case .auto: "Runs anything on its own. Only for throwaway folders"
        }
    }

    private func trustLine(_ level: Autonomy) -> String {
        switch level {
        case .ask: "I'll ask before I even look."
        case .allowlist: "I'll ask once, then remember."
        case .trusted: "I'll look around, and ask before I change or send anything."
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

/// The recap's "Change" link: the app's small ghost button, a real 28pt target with a hover.
private struct OnboardingChangeButton: View {
    let key: String
    let action: () -> Void

    init(key: String, action: @escaping () -> Void) {
        self.key = key
        self.action = action
    }

    var body: some View {
        Button("Change", action: action)
            .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .sm))
            .help("Go back and change the \(key.lowercased())")
        .accessibilityLabel("Change \(key.lowercased())")
    }
}
