import Foundation

/// Messages typed while a bot was busy, joined into the one prompt it gets when it is free.
public enum QueuedMessages {
    public static func prompt(_ messages: [String]) -> String? {
        let clean = messages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return nil }
        if clean.count == 1 { return clean[0] }
        return "I sent these while you were working:\n\n" + clean.map { "- \($0)" }.joined(separator: "\n")
    }
}
