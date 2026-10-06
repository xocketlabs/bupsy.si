import BupsyKit
import SwiftUI

/// The measurements a conversation is laid out on, taken from the design's Message component.
///
/// A bot's reply leads with a 28pt face and a 12pt gap, so everything that belongs to that reply
/// (tool lines, cards, the thinking line) sits 40pt in, under the words rather than under the face.
enum ThreadLayout {
    static let avatar: CGFloat = 28
    static let avatarGap: CGFloat = 12
    static var gutter: CGFloat { avatar + avatarGap }
    /// max-w-4xl, the column the transcript and the composer share.
    static let columnMaxWidth: CGFloat = 896
    /// Cards in a thread stop here so a wide window does not stretch a decision into a banner.
    static let cardMaxWidth: CGFloat = 640
    /// One size for what was said and what you are typing, so a message does not shrink the
    /// moment you send it. The design sets both at 16; through `Theme.scaled` so the app's one
    /// text-size knob still moves it.
    static let messageSize: CGFloat = Theme.scaled(14.3)
    static let messageFont = Font.system(size: messageSize)
    static let metaFont = Font.system(size: Theme.scaled(12.5))
    static let monoFont = Font.system(size: Theme.scaled(11.5), design: .monospaced)
}

/// What one transcript row needs to know about the rows around it, worked out once per thread
/// change by whoever lays the rows out, so no row reads the whole thread while drawing.
///
/// Build the whole list with `rows(for:isRunning:)` (one pass over the entries) and hand each
/// `Bubble` the element at its own index. A `Bubble` given no context falls back to the cheap
/// parts it can know alone (whether the bot is running) and shows no thinking time.
struct ThreadRowContext: Equatable, Sendable {
    /// Whether the run this thread belongs to is still going.
    var isRunning = false
    /// How long the bot thought, for a thinking row that opens a turn ("8s"). Nil elsewhere.
    var thinkingDuration: String?
    /// This is the last of your messages waiting for the bot, and carries the "Queued" line.
    var showsQueuedNote = false
    /// This row is the model's queued note, drawn under your bubble instead of on its own.
    var isQueuedNote = false
    /// Whether this row's approval card owns Shift Cmd A and Shift Cmd D. Only the newest
    /// pending card does, so one shortcut can never answer a card you were not looking at.
    var bindsApprovalShortcuts = true

    init(isRunning: Bool = false, thinkingDuration: String? = nil, showsQueuedNote: Bool = false,
         isQueuedNote: Bool = false, bindsApprovalShortcuts: Bool = true) {
        self.isRunning = isRunning
        self.thinkingDuration = thinkingDuration
        self.showsQueuedNote = showsQueuedNote
        self.isQueuedNote = isQueuedNote
        self.bindsApprovalShortcuts = bindsApprovalShortcuts
    }

    /// One context per entry, index for index, in a single pass plus two backward searches.
    static func rows(for entries: [TranscriptEntry], isRunning: Bool) -> [ThreadRowContext] {
        var rows = Array(repeating: ThreadRowContext(isRunning: isRunning), count: entries.count)
        var newestPendingApproval: Int?

        for index in entries.indices {
            switch entries[index].kind {
            case .thinking:
                // Engines hand reasoning over whole, so the gap since the message that started
                // the turn is the thinking time. Anywhere else the start is not recorded, and no
                // duration is shown rather than a guessed one.
                guard index > 0 else { break }
                switch entries[index - 1].kind {
                case .userMessage, .messageFrom:
                    rows[index].thinkingDuration = ChatDuration.whole(
                        entries[index].at.timeIntervalSince(entries[index - 1].at))
                default:
                    break
                }
            case .approval(let approval):
                rows[index].bindsApprovalShortcuts = false
                if approval.decided == nil { newestPendingApproval = index }
            default:
                break
            }
        }
        if let newestPendingApproval { rows[newestPendingApproval].bindsApprovalShortcuts = true }

        // The model's note sits after the first message you queued; later ones land below it.
        // The line belongs under the last of them, where your eye is.
        if let note = entries.lastIndex(where: { holdsQueuedNote($0.kind) }) {
            let after = entries.index(after: note)
            let target = entries[after...].lastIndex(where: { isUserMessage($0.kind) })
                ?? entries[..<note].lastIndex(where: { isUserMessage($0.kind) })
            if let target {
                rows[note].isQueuedNote = true
                rows[target].showsQueuedNote = true
            }
        }
        return rows
    }

    /// The note the model adds while messages wait for a busy bot.
    static func holdsQueuedNote(_ kind: TranscriptEntry.Kind) -> Bool {
        if case .note(let text) = kind { return text.hasPrefix("Queued") }
        return false
    }

    private static func isUserMessage(_ kind: TranscriptEntry.Kind) -> Bool {
        if case .userMessage = kind { return true }
        return false
    }
}

/// A tool call's arguments, read once: how the thread shows it, the one-line target, the
/// paths it may have touched, and the description the bot gave, if any.
struct ToolCallInfo: Equatable, Sendable {
    let line: BupsyToolLine
    /// The command, path, pattern or URL, whichever the call has first. The tool's name when
    /// it has none of those; empty when the arguments are not JSON.
    let summary: String
    /// Paths named in the arguments. Whether they exist is checked off the drawing path.
    let pathCandidates: [String]

    init(tool: String, argumentsJSON: String) {
        let object = ToolCallInfo.object(argumentsJSON)
        line = BupsyToolLine(tool: tool, arguments: object ?? [:])
        if let object {
            var found: String?
            for key in ["command", "file_path", "path", "pattern", "url", "query", "description"] {
                if let value = object[key] as? String, !value.isEmpty { found = value; break }
            }
            summary = found ?? tool
            pathCandidates = ["file_path", "path", "notebook_path"].compactMap {
                guard let value = object[$0] as? String, !value.isEmpty else { return nil }
                return value
            }
        } else {
            summary = ""
            pathCandidates = []
        }
    }

    static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Remembers the last `ToolCallInfo` worked out for one row, so redrawing the row does not
/// parse its JSON again. Held in a row's `@State`; not observable, so filling it never asks
/// for another redraw. Only ever touched from that row's body.
final class ToolCallMemo {
    private var key: (tool: String, arguments: String)?
    private var value: ToolCallInfo?

    init() {}

    func info(tool: String, arguments: String) -> ToolCallInfo {
        if let key, let value, key.tool == tool, key.arguments == arguments { return value }
        let fresh = ToolCallInfo(tool: tool, argumentsJSON: arguments)
        key = (tool: tool, arguments: arguments)
        value = fresh
        return fresh
    }
}

/// A small status pill for the topbar: tone-washed, optionally led by a dot.
struct ThreadStatusBadge: View {
    @Environment(\.palette) private var palette
    let text: String
    var tone: Color?
    var dot = false

    var body: some View {
        let colour = tone ?? palette.mutedForeground
        HStack(spacing: 6) {
            if dot {
                Circle().fill(colour).frame(width: 6, height: 6)
            }
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(colour)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(colour.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.control))
    }
}

/// The buttons a thread uses, at the design's 36pt in-card size.
struct ThreadButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, ghostDestructive }

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var kind: Kind = .secondary
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.body)
            .fontWeight(kind == .primary ? .medium : .regular)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost || kind == .ghostDestructive ? 10 : 14)
            .frame(height: height)
            .background(background(pressed: configuration.isPressed),
                        in: .rect(cornerRadius: Theme.Radius.control))
            .shadow(color: kind == .primary && isEnabled ? palette.primary.opacity(0.35) : .clear,
                    radius: 2, y: 1)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(.rect)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary, .ghost: palette.foreground
        case .ghostDestructive: palette.destructiveText
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: palette.primary.opacity(pressed ? 0.85 : 1)
        case .secondary: pressed ? palette.cardHover : palette.card
        case .ghost, .ghostDestructive: pressed ? palette.cardHover : .clear
        }
    }
}

/// agndex's nested card: a lip around an inner card, with a quiet footer living on the lip.
///
/// The lip is passed in, so an approval can wear pink and a question plain grey, in the same
/// shape. `wash` is laid over `base`, which is how a tint "mixed into" a surface is drawn without
/// `Color.mix`.
struct ThreadNestedCard<Content: View, Footer: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let base: Color
    var wash: Color?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            VStack(alignment: .leading, spacing: Theme.Space.step) { content }
                .padding(Theme.Space.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colorScheme == .dark ? palette.card : palette.background,
                            in: .rect(cornerRadius: Theme.Radius.base))
            footer
                .padding(.horizontal, Theme.Space.step)
        }
        .padding([.top, .horizontal], 2)
        .padding(.bottom, Theme.Space.step)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.bubble).fill(base)
                if let wash {
                    RoundedRectangle(cornerRadius: Theme.Radius.bubble).fill(wash)
                }
            }
        }
        .frame(maxWidth: ThreadLayout.cardMaxWidth, alignment: .leading)
    }
}

/// A bot peeking over the top edge of the composer while it works, paws on the rim.
///
/// The same idea as `SheetFrame`'s peek, at the composer's smaller size: the face is cut off
/// below the eyes so it reads as hiding behind the box, and the two paws are drawn in front of
/// the rim so it is clearly holding on.
struct ThreadComposerPeek: View {
    let bot: Bot

    init(bot: Bot) { self.bot = bot }

    /// How much of the face shows above the rim.
    private let visible: CGFloat = 30
    private let size: CGFloat = 44

    var body: some View {
        ZStack(alignment: .topLeading) {
            BotFace(bot: bot, mood: .working, size: size)
                .frame(width: size, height: visible, alignment: .top)
                .clipped()
            paw(x: 7, angle: -6)
            paw(x: 27, angle: 6)
        }
        .frame(width: size, height: visible + 4, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func paw(x: CGFloat, angle: Double) -> some View {
        let index = (bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue)) % BotShape.rgbPalette.count
        let tint = BotShape.rgbPalette[index]
        let fill = LinearGradient(colors: [tint.mixed(with: .hex(0xFFFFFF), 0.62).color, tint.color],
                                  startPoint: .top, endPoint: .bottom)
        let rim = tint.mixed(with: .hex(0x000000), 0.72).color.opacity(0.5)
        return UnevenRoundedRectangle(cornerRadii: .init(topLeading: 6, bottomLeading: 4,
                                                         bottomTrailing: 4, topTrailing: 6))
            .fill(fill)
            .shadow(color: rim, radius: 0.5, y: 1)
            .frame(width: 10, height: 7)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: visible - 3)
    }
}
