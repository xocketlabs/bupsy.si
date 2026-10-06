import Foundation

/// Reads named environment variables the way the person's own terminal sets them.
///
/// The same trap as `BinaryResolver`: an app opened from Finder inherits launchd's environment,
/// not the one `~/.zshrc` or `~/.zprofile` builds. A connector whose setup says "set
/// LINEAR_API_KEY in your shell, then restart Bupsy" could never work if Bupsy only looked at its
/// own environment. So the names a connector needs are asked of a login shell instead.
///
/// **Values are never logged, stored or written to a file.** They are held in memory for this
/// launch, so a value set later is picked up on the next launch, which is what the setup copy
/// tells people to do. Only names a connector asked for are read, never the whole environment.
public enum LoginShellEnvironment {
    /// The value for each name: this process's own if it has one, otherwise the login shell's.
    /// Names with no value anywhere are left out. Blocks while a login shell runs for names not
    /// yet looked up this launch, so call it off the main thread where that matters.
    public static func resolved(
        _ names: [String],
        current: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]
        var needShell: [String] = []
        for name in names {
            if let value = current[name], !value.isEmpty {
                result[name] = value
            } else {
                needShell.append(name)
            }
        }
        if !needShell.isEmpty {
            for (name, value) in cache.values(for: needShell) { result[name] = value }
        }
        return result
    }

    /// Looks the names up now, so a later `resolved` call does not wait on a shell.
    public static func prefetch(_ names: [String]) {
        _ = resolved(names)
    }

    // MARK: - Parsing, kept separate so it can be tested without a shell

    /// A variable name safe to place in a shell command: letters, digits and underscore, not
    /// starting with a digit. Anything else is never sent to the shell.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty else { return false }
        func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            let value = scalar.value
            return (65...90).contains(value) || (97...122).contains(value) || value == 95
        }
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { (48...57).contains(scalar.value) }
        guard isLetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { isLetter($0) || isDigit($0) }
    }

    /// The command the login shell runs: each name and its value, NUL separated, so a value
    /// holding a newline or an equals sign comes back intact. It starts with a NUL of its own, so
    /// whatever a profile prints first ("Hi", a version manager's banner) is a record of its own
    /// and is dropped, instead of being glued to the first name.
    static func script(for names: [String]) -> String {
        let valid = names.filter { isValidName($0) }
        guard !valid.isEmpty else { return "" }
        return (["printf '\\0'"] + valid.map { "printf '%s\\0' \"\($0)=$\($0)\"" })
            .joined(separator: "; ")
    }

    /// Reads the shell's output back. Only the asked-for names are kept, and empty values count
    /// as unset, the same rule `MCPServer.missingEnv` applies.
    static func parse(_ data: Data, names: [String]) -> [String: String] {
        let wanted = Set(names)
        var result: [String: String] = [:]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let text = String(data: Data(record), encoding: .utf8),
                  let equals = text.firstIndex(of: "=") else { continue }
            let name = String(text[..<equals])
            let value = String(text[text.index(after: equals)...])
            guard wanted.contains(name), !value.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    // MARK: - Shell

    private static let cache = Cache()

    /// One lookup per name per launch. A class with a lock rather than an actor because callers
    /// are synchronous (a view checking what is missing), and the lock is held only around
    /// dictionary access, never while the shell runs.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        /// nil value means "asked, and the shell has none".
        private var known: [String: String?] = [:]

        func values(for names: [String]) -> [String: String] {
            lock.lock()
            let unknown = names.filter { known[$0] == nil }
            lock.unlock()

            if !unknown.isEmpty {
                let fetched = LoginShellEnvironment.readFromShell(unknown)
                lock.lock()
                for name in unknown { known[name] = .some(fetched[name]) }
                lock.unlock()
            }

            lock.lock()
            defer { lock.unlock() }
            var result: [String: String] = [:]
            for name in names {
                if let entry = known[name], let value = entry { result[name] = value }
            }
            return result
        }
    }

    /// How long a profile gets before it is given up on: long enough for nvm or conda to start,
    /// short enough that a profile that never returns (one that attaches to tmux) costs little.
    static let shellTimeout: TimeInterval = 5

    private static func readFromShell(_ names: [String]) -> [String: String] {
        #if os(Windows)
        return [:]
        #else
        let command = script(for: names)
        guard !command.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        // Interactive as well as login: zsh reads `~/.zshrc`, where most people export things,
        // only for an interactive shell. Nothing to read from, so it never waits on input.
        process.arguments = ["-i", "-l", "-c", command]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return [:] }
        // Read while it runs, so a chatty profile cannot fill the pipe and stall the shell.
        let output = Output()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            read.signal()
        }
        guard exited.wait(timeout: .now() + shellTimeout) == .success else {
            process.terminate()
            return [:]
        }
        // Something the profile started in the background can hold the pipe open after the
        // shell itself is gone; what was printed is already there.
        guard read.wait(timeout: .now() + 1) == .success,
              process.terminationStatus == 0 else { return [:] }
        return parse(output.get(), names: names)
        #endif
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
