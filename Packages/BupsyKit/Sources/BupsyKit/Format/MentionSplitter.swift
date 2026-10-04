import Foundation

/// Finds "@Name" mentions of known bots in a run of text.
///
/// Longest names first, so "@Email Agent 3" is not read as a mention of "Email"; case-insensitive;
/// and a mention must end at a word boundary, so "@Scouting" is not Scout. The same rules as
/// group routing, so what is highlighted is exactly what summons a bot.
public enum MentionSplitter {
    public enum Piece: Equatable, Sendable { case text(String), mention(String) }

    public static func split(_ text: String, names: [String]) -> [Piece] {
        guard text.contains("@"), !names.isEmpty else { return [.text(text)] }
        let ordered = names.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var pieces: [Piece] = []
        var buffer = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@" {
                let after = text.index(after: index)
                let match = ordered.first { name in
                    guard let end = text.index(after, offsetBy: name.count, limitedBy: text.endIndex),
                          text[after..<end].compare(name, options: .caseInsensitive) == .orderedSame
                    else { return false }
                    return end == text.endIndex || !(text[end].isLetter || text[end].isNumber)
                }
                if let match {
                    if !buffer.isEmpty { pieces.append(.text(buffer)); buffer = "" }
                    pieces.append(.mention(match))
                    index = text.index(after, offsetBy: match.count)
                    continue
                }
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        if !buffer.isEmpty { pieces.append(.text(buffer)) }
        return pieces
    }
}
