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
            for variant in variants {
                result = result.replacingOccurrences(of: variant + "/", with: replacement.isEmpty ? "" : replacement + "/")
                result = result.replacingOccurrences(of: variant, with: replacement.isEmpty ? "." : replacement)
            }
        }
        return result
    }
}
