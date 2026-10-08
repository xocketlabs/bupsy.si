import SwiftUI

/// The frame shared by everything that waits on the person: a faint pink card with a pink edge,
/// so it stands apart from the conversation around it.
private struct WaitingCard: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: Theme.Size.cardMaxWidth, alignment: .leading)
            .background(palette.tint, in: shape)
            .overlay(shape.strokeBorder(palette.tintBorder))
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

/// A bot asking to do something: what exactly, in mono, why, and Allow or Deny.
///
/// Allow asks for Face ID or the passcode first (see `OwnerCheck`); Deny never does.
struct ApprovalCard: View {
    @Environment(\.palette) private var palette
    let approval: Approval
    let botName: String
    let chat: ChatModel
    @State private var expanded = false

    /// Long commands stop after eight lines, with a way to read the rest: what comes after the
    /// cut (`… && rm -rf ~`) can be the part that matters, so it must be one tap away.
    private var isLong: Bool {
        approval.summary.split(separator: "\n", omittingEmptySubsequences: false).count > 8
            || approval.summary.count > 600
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(botName.isEmpty ? "Your bot" : botName) wants to \(approval.action)")
                .font(.body.weight(.semibold))
            if !approval.summary.isEmpty {
                Text(approval.summary)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(expanded ? nil : 8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(palette.recess, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                if isLong, !expanded {
                    Button("Show all") { expanded = true }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.primary)
                }
            }
            if !approval.reason.isEmpty {
                Text(approval.reason)
                    .font(.subheadline)
                    .foregroundStyle(palette.mutedForeground)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Deny") {
                    Task { await chat.decide(approval, allow: false) }
                }
                .buttonStyle(.bupsySecondary)
                Button("Allow") {
                    Task { await chat.decide(approval, allow: true) }
                }
                .buttonStyle(.bupsyPrimary)
            }
            .padding(.top, 4)
            .disabled(chat.answering.contains(approval.id))
        }
        .modifier(WaitingCard())
        .accessibilityElement(children: .contain)
    }
}

/// A question the bot asked, with its answers as buttons, or a box when it offered none.
struct QuestionCard: View {
    @Environment(\.palette) private var palette
    let question: Question
    let botName: String
    let chat: ChatModel
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question.isEmpty ? "\(botName.isEmpty ? "Your bot" : botName) has a question" : question.question)
                .font(.body.weight(.semibold))
            if question.options.isEmpty {
                HStack(spacing: 8) {
                    TextField("Your answer", text: $typed, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(palette.background, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .onSubmit(answerTyped)
                    Button("Answer", action: answerTyped)
                        .buttonStyle(.bupsyPrimary)
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(question.options, id: \.self) { option in
                        Button(option) {
                            Task { await chat.answer(question, with: option) }
                        }
                        .buttonStyle(BupsyButtonStyle(kind: .secondary, wide: true))
                    }
                }
            }
        }
        .disabled(chat.answering.contains(question.id))
        .modifier(WaitingCard())
        .accessibilityElement(children: .contain)
    }

    private func answerTyped() {
        let answer = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        Task { await chat.answer(question, with: answer) }
    }
}
