import SwiftUI

/// One bot's chat: its conversation, kept at the bottom as it grows, and a box to write in.
struct ChatView: View {
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    private let session: AppSession
    @State private var chat: ChatModel
    /// Whether the end of the conversation is on screen. New messages only pull the view down
    /// when it is: someone who scrolled up to read is left where they are.
    @State private var atBottom = true
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var composing: Bool

    private static let end = "end"

    init(botID: String, session: AppSession) {
        self.session = session
        _chat = State(initialValue: ChatModel(botID: botID, session: session))
    }

    var body: some View {
        let bot = chat.bot
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if chat.loaded, chat.entries.isEmpty {
                        NoteLine(text: "No messages yet. Say hello.")
                    }
                    ForEach(ThreadRow.rows(chat.entries)) { row in
                        EntryView(row: row, bot: bot, chat: chat)
                    }
                    if bot.running, !bot.needsYou {
                        TypingBubble()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.end)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.entries) { before, _ in
                // The first load jumps; later ones glide, and only for someone already at the end.
                if before.isEmpty {
                    proxy.scrollTo(Self.end, anchor: .bottom)
                } else if atBottom {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
            .onChange(of: bot.running) {
                if atBottom { withAnimation { proxy.scrollTo(Self.end, anchor: .bottom) } }
            }
            .onChange(of: composing) {
                // The keyboard shrinks the view from below; keep the latest message above it.
                guard composing, atBottom else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer(for: bot)
            }
        }
        .background(palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatHeader(bot: bot)
            }
            if bot.running {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await chat.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(palette.foreground)
                }
            }
        }
        // Every 1.5 seconds while this chat is on screen and the app is in the foreground.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await chat.poll()
        }
        .onAppear {
            draft = session.drafts[chat.botID] ?? ""
            session.alerts.clear(chat.botID)
        }
        .onChange(of: draft) { _, text in
            session.drafts[chat.botID] = text.isEmpty ? nil : text
        }
    }

    private func composer(for bot: Bot) -> some View {
        VStack(spacing: 8) {
            if let problem = chat.problem {
                Toast(message: problem)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(bot.name.isEmpty ? "Message" : "Message \(bot.name)", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.border))
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(width: 38, height: 38)
                        .background(palette.primary, in: Circle())
                }
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.35)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(alignment: .top) {
                palette.background
                    .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft
        guard canSend else { return }
        draft = ""
        sending = true
        // Your own message always brings the view to the end, wherever it was.
        atBottom = true
        Task {
            if !(await chat.send(text)), draft.isEmpty { draft = text }
            sending = false
        }
    }
}

/// The bot's face, name and what it's doing, in the navigation bar.
private struct ChatHeader: View {
    @Environment(\.palette) private var palette
    let bot: Bot

    var body: some View {
        HStack(spacing: 8) {
            Avatar(bot: bot, size: Theme.Size.headerAvatar)
            VStack(alignment: .leading, spacing: 0) {
                Text(bot.name)
                    .font(.headline)
                    .lineLimit(1)
                if bot.needsYou {
                    Text("Waiting on you")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.primary)
                } else if bot.running {
                    Text("Working…")
                        .font(.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
