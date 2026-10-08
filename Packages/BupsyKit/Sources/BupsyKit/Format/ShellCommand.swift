import Foundation

/// Which code blocks are shell commands someone could run, and the command to run.
public enum ShellCommand {
    /// Languages that mean "type this in a terminal".
    public static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "shell", "console", "terminal", "command"]

    /// The command a block holds, or nil when it is not one.
    ///
    /// A shell-labelled block always is. An unlabelled one is when it is a few lines whose first
    /// word is a program on this Mac, which catches the commands models write without a label
    /// ("open …", "ls …") while leaving prose, JSON and other code alone. A leading "$ " prompt
    /// is dropped, as people copying from a terminal do.
    public static func command(language: String?, text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("$ ") ? String(trimmed.dropFirst(2)) : String(line)
            }
        let command = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        if let language = language?.lowercased(), !language.isEmpty {
            return shellLanguages.contains(language) ? command : nil
        }
        guard lines.count <= 5,
              let first = command.split(whereSeparator: { $0 == " " || $0 == "\n" }).first,
              isProgram(String(first))
        else { return nil }
        return command
    }

    /// Whether a word names a program in the usual places, or a shell builtin people type.
    public static func isProgram(_ word: String) -> Bool {
        if ["cd", "export", "echo", "source", "."].contains(word) { return true }
        guard !word.contains("/"), word.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) })
        else { return false }
        let folders = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
        return folders.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(word)") }
    }

    /// Commands worth a second look before they run: ones that delete, escalate, overwrite a
    /// disk, run a downloaded script or rewrite shared history. A heuristic for a confirmation,
    /// never a sandbox; everything else runs on the click, which is the point of the button.
    public static func needsConfirmation(_ command: String) -> Bool {
        let lowered = " " + command.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let risky = [" rm ", " sudo ", " dd ", " mkfs", " shred ", " diskutil ", "| sh ", "| bash ",
                     "| zsh ", " --force", " push ", " reset --hard", " chmod -r", " chown -r",
                     " kill ", " killall ", " launchctl ", " > /"]
        return risky.contains { lowered.contains($0) }
    }
}
