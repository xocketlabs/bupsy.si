import Foundation

/// Makes a command readable on an approval card by shortening the paths in it.
///
/// Bots work in their own folder, so nearly every command repeated a long private path — one
/// `printf` became seven lines, and the part worth reading (what it does) was the part you could
/// no longer see. The bot's folder becomes nothing (paths read relative to it), the home folder
/// becomes `~`. Display only: the full input is still one click away under Details.
public enum PathShortener {
    public static func shorten(_ text: String, workingDirectory: String?, home: String = NSHomeDirectory()) -> String {
        var result = text
        // Longest prefix first: the working folder usually lives inside home.
        for (prefix, replacement) in [(workingDirectory, ""), (home, "~")] {
            guard var prefix, !prefix.isEmpty else { continue }
            if prefix.hasSuffix("/") { prefix.removeLast() }
            // macOS reports /tmp paths as both /tmp and /private/tmp.
            let variants = prefix.hasPrefix("/private/") ? [prefix, String(prefix.dropFirst(8))]
                : [prefix, "/private" + prefix]
            // Longer spelling first, or /tmp/x would eat the tail of /private/tmp/x/… and leave
            // "/private" glued to what follows.
            for variant in variants.sorted(by: { $0.count > $1.count }) {
                result = replace(variant, in: result, with: replacement)
            }
        }
        return result
    }

    /// Replaces `prefix` only where it is a whole path: followed by `/` or by something that
    /// cannot continue a folder name. A plain substring replace turned /x/proj-other into
    /// ".-other" and /Users/vanshika into "~ika" — both claim a different path than the real one.
    static func replace(_ prefix: String, in text: String, with replacement: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: prefix) {
            let after = rest[range.upperBound...]
            result += rest[..<range.lowerBound]
            if after.first == "/" {
                result += replacement.isEmpty ? "" : replacement + "/"
                rest = after.dropFirst()
            } else if after.first.map(endsPath) ?? true {
                result += replacement.isEmpty ? "." : replacement
                rest = after
            } else {
                // Part of a longer name: keep it as written.
                result += rest[range]
                rest = after
            }
        }
        return result + rest
    }

    /// Characters that end a path inside a command: whitespace, quotes and shell punctuation.
    /// Anything else (letters, digits, `-`, `_`, `.`) could be the rest of a folder name.
    private static func endsPath(_ character: Character) -> Bool {
        character.isWhitespace || "'\"`;|&)><:,".contains(character)
    }
}
