import BupsyKit
import SwiftUI

/// Something that cannot move without a person.
struct AttentionItem: Identifiable, Hashable {
    enum Kind: Hashable { case approval, objective }

    let id: String
    let botName: String
    let hue: Double
    let kind: Kind
    let title: String
    let detail: String
}

/// One place for everything waiting on you.
///
/// The thing that makes standing goals usable rather than alarming. A bot that works unattended
/// will inevitably reach something only a person can settle, and without a single list those
/// land scattered across threads nobody is reading. A count on the sidebar is the difference
/// between autonomy and things quietly stalling.
struct AttentionInbox: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Waiting on you").font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            if model.attentionItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("Nothing needs you").font(.callout)
                    Text("Approvals and stuck goals turn up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                List {
                    ForEach(model.attentionItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            BotFace(hue: item.hue, mood: .waitingForYou, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).fontWeight(.medium)
                                if !item.detail.isEmpty {
                                    Text(item.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.botName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Button("Open") { model.selectedBotID = botID(for: item) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 3)
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
        .frame(width: 540, height: 400)
    }

    private func botID(for item: AttentionItem) -> BotID? {
        model.bots.first { $0.name == item.botName }?.id
    }
}
