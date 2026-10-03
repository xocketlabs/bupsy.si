import Foundation

/// Replying to one message: what is sent to the engine, and how it is read back.
///
/// A reply is a markdown quote followed by the message. That is the whole format, on purpose: it
/// is what a model already understands as "this refers to that", it needs no new field in the
/// event log, and the stored text is exactly what the engine received — so the audit trail and the
/// screen can never disagree about what the bot was shown.
///
/// Measured motivation: asked "what means of this ?" with no way to point at a message, a bot
/// had to answer "I'm not sure what you're pointing at."
public enum Reply {

    /// Quoted text is capped. A reply points at a message; it should not re-send a long answer in
    /// full on every turn, spending the person's own quota on something the bot already said.
    public static let quoteLimit = 600

    /// `> who: quoted text` then a blank line, then the message.
    public static func compose(quoting quote: String, from author: String, message: String) -> String {
        let flat = quote
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = flat.count > quoteLimit ? String(flat.prefix(quoteLimit)) + "…" : flat
        return "> \(author): \(clipped)\n\n\(message)"
    }

    /// Splits a stored message back into the quote it replied to, if any, and its own text.
    ///
    /// Only a leading quote counts. A message that merely *contains* a `>` line further down was
    /// someone quoting something themselves, not a reply.
    public static func split(_ text: String) -> (author: String?, quote: String?, body: String) {
        guard text.hasPrefix("> "),
              let breakRange = text.range(of: "\n\n") else {
            return (nil, nil, text)
        }
        let header = String(text[text.index(text.startIndex, offsetBy: 2)..<breakRange.lowerBound])
        let body = String(text[breakRange.upperBound...])
        // A quote line is one line. Anything spanning several was not written by compose().
        guard !header.contains("\n"), !body.isEmpty else { return (nil, nil, text) }

        if let colon = header.range(of: ": ") {
            return (String(header[..<colon.lowerBound]),
                    String(header[colon.upperBound...]), body)
        }
        return (nil, header, body)
    }
}
