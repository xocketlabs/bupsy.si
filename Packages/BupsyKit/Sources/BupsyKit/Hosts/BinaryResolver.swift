import Foundation

/// Finds an engine binary the way a human's shell would.
///
/// This exists because of a real trap: **a GUI app's PATH is not your terminal's PATH.**
/// A launched .app inherits a minimal environment from launchd, so `claude` — commonly
/// installed to `~/.local/bin` or Homebrew — is simply not found. Resolving through a
/// login shell picks up whatever the user's own profile puts on PATH.
///
/// Verified by spike 3c. On this machine `claude` lives at `~/.local/bin/claude`, which is
/// on none of the default system paths.
public enum BinaryResolver {
    /// Extra locations checked before falling back to the shell, cheapest first.
    ///
    /// Unix layout. Windows has none of these, resolves through PATH plus PATHEXT, and is handled
    /// in `resolveViaShell` instead.
    private static let commonDirectories = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.bun/bin",
        "\(NSHomeDirectory())/.volta/bin",
        "/usr/bin",
        // /bin holds sh, cat, pwd and friends. Its absence was masked for a while by the login
        // shell fallback, which resolves most of them — but not the ones that are also shell
        // builtins, where `command -v` answers with the builtin's name and no path at all.
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// The PATH a spawned engine should get: the person's login-shell PATH, the common install
    /// locations, then whatever this process already had — each once, in that order.
    ///
    /// Without it, a bupsy opened from Finder hands the engine launchd's bare
    /// `/usr/bin:/bin:/usr/sbin:/sbin`. The engine itself is found (we resolve it to a full path),
    /// but everything *it* starts is not: an MCP server run through `npx`, or a Node tool whose
    /// first line is `#!/usr/bin/env node`, fails with "not found" for no reason anyone can see.
    public static func searchPath(current: String?, login: String? = loginShellPath) -> String {
        var seen = Set<String>()
        let parts = [login, commonDirectories.joined(separator: ":"), current]
            .compactMap { $0 }
            .flatMap { $0.split(separator: ":").map(String.init) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return parts.joined(separator: ":")
    }

    /// The login shell's PATH, read once per launch. Nil if the shell could not be asked.
    public static let loginShellPath: String? = {
        #if os(Windows)
        return nil
        #else
        // Through `LoginShellEnvironment.runLoginShell`, which gives up after a timeout. This
        // used to wait on the shell with no limit, inside a `static let` every spawn touches —
        // so one profile that held stdout open hung every engine launch for the rest of the
        // session. NUL-delimited, because the interactive shell's profile may print around it.
        guard let output = LoginShellEnvironment.runLoginShell("printf '\\0%s\\0' \"$PATH\""),
              let path = LoginShellEnvironment.delimited(output), !path.isEmpty
        else { return nil }
        return path
        #endif
    }()

    /// - Parameter name: a bare binary name, or an absolute path the user chose in Settings.
    public static func resolve(_ name: String) throws -> URL {
        if name.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: name) else {
                throw HostError.binaryNotFound(name)
            }
            return URL(fileURLWithPath: name)
        }

        #if !os(Windows)
        for dir in commonDirectories {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        #endif

        if let viaShell = try? resolveViaShell(name) { return viaShell }
        throw HostError.binaryNotFound(name)
    }

    /// Asks the shell where the binary is.
    ///
    /// On Unix this runs a *login* shell, so `~/.zprofile` and friends are honoured — which
    /// matters because a GUI app inherits launchd's minimal PATH and would otherwise find
    /// nothing. Windows has no equivalent problem and no equivalent shell, so it uses `where`.
    private static func resolveViaShell(_ name: String) throws -> URL {
        #if os(Windows)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let waitForExit = try process.launchForWaiting()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        waitForExit()
        guard process.terminationStatus == 0 else { throw HostError.binaryNotFound(name) }
        let output = String(data: data, encoding: .utf8)
        #else
        // A login shell so profile files load, with the same timeout every login-shell lookup
        // gets. command -v is POSIX and avoids shell builtins' quirks. The name is single-quoted
        // so it reaches `command -v` as one word: it can come from Settings, and unquoted a
        // name holding a space, `;` or `$(…)` was run by the shell rather than looked up.
        //
        // The shell is interactive, so it has the person's aliases and functions, and
        // `command -v` reports those ahead of the binary ("alias claude=…"), which is no path.
        // They are dropped in this throwaway shell first so the answer is the file on PATH.
        let word = shellQuoted(name)
        let script = "unalias \(word) 2>/dev/null; unset -f \(word) 2>/dev/null; "
            + "printf '\\0'; command -v \(word); printf '\\0'"
        guard let data = LoginShellEnvironment.runLoginShell(script)
        else { throw HostError.binaryNotFound(name) }
        let output = LoginShellEnvironment.delimited(data)
        #endif

        // `where` can return several matches, one per line. The first is what the shell would run.
        guard let output,
              let path = output.split(separator: "\n").first
                  .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { throw HostError.binaryNotFound(name) }

        return URL(fileURLWithPath: path)
    }

    /// `name` as one single-quoted shell word, with any `'` inside closed, escaped and reopened.
    static func shellQuoted(_ name: String) -> String {
        "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
