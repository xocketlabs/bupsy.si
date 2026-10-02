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
        let process = Process()
        #if os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
        process.arguments = [name]
        #else
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        // -l so profile files load; command -v is POSIX and avoids shell builtins' quirks.
        process.arguments = ["-l", "-c", "command -v \(name)"]
        #endif
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // `where` can return several matches, one per line. The first is what the shell would run.
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8),
              let path = output.split(separator: "\n").first
                  .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { throw HostError.binaryNotFound(name) }

        return URL(fileURLWithPath: path)
    }
}
