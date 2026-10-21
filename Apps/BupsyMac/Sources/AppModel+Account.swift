import AppKit
import BupsyKit
import Foundation

/// Signing an engine in and out, the way docs/00-compliance-and-auth.md allows it.
///
/// Both directions run the vendor's own, unmodified CLI in a Terminal window the person can see
/// and control, the same `.command` pattern the Executor installer uses. bupsy writes a short
/// readable script, opens it, and never reads what happens inside it. Afterwards the only thing
/// it learns is the CLI's own verdict from `refreshEngineStatus()`: no file under the CLI's
/// config folder is opened, nothing is parsed out of the session, nothing is stored.
extension AppModel {
    /// Set when a sign-in or sign-out window was opened, so the next time Bupsy comes forward the
    /// engines are asked again. Asked then rather than on a timer, because the Claude Code check
    /// is a real (tiny) prompt, and polling one every few seconds would spend the person's limit.
    static let authCheckPendingKey = "bupsy.authCheckPending"

    /// Opens Terminal running the engine's own sign-in, exactly as its adapter defines it.
    /// Fire and forget; a failure lands in `accountProblem`.
    func openSignIn(for engine: EngineID) {
        Task { await signIn(to: engine) }
    }

    /// Opens Terminal running the engine's own sign-out command, if its CLI has one.
    /// Fire and forget; a failure lands in `accountProblem`.
    func openSignOut(for engine: EngineID) {
        Task { await signOut(of: engine) }
    }

    /// Opens the engine's own sign-in in Terminal. Returns false, and sets `accountProblem` to a
    /// sentence the UI can show, if the window could not be opened. True means Terminal was
    /// asked to open it, not that the person finished signing in: that is learned afterwards
    /// from `refreshEngineStatus()`.
    @discardableResult
    func signIn(to engine: EngineID) async -> Bool {
        accountProblem = nil
        guard let login = Self.loginCommand(for: engine),
              let binary = login.command.split(separator: " ").map(String.init).first else {
            accountProblem = "Bupsy doesn't know how to sign in to \(engine.displayName)."
            return false
        }
        let parts = login.command.split(separator: " ").map(String.init)
        let arguments = parts.dropFirst().map { Self.shellQuoted($0) }.joined(separator: " ")
        let call = arguments.isEmpty ? "\"$CLI\"" : "\"$CLI\" \(arguments)"
        let intro = Self.signInIntro(for: engine)
        return await openAccountScript(
            named: "Sign in to \(engine.displayName)", binary: binary,
            body: intro.map { "echo \(Self.shellQuoted($0))" }.joined(separator: "\n")
                + "\necho\n" + call + "\n")
    }

    /// Opens the engine's own sign-out in Terminal. Returns false and sets `accountProblem` if
    /// it could not be opened.
    ///
    /// Whether the command exists is checked inside the script, against the CLI's own `--help`,
    /// so an older build that lacks it gets an explanation rather than a confusing error.
    @discardableResult
    func signOut(of engine: EngineID) async -> Bool {
        accountProblem = nil
        guard let script = Self.signOutScript(for: engine) else {
            accountProblem = "Bupsy can't sign out of \(engine.displayName) from here."
            return false
        }
        return await openAccountScript(named: "Sign out of \(engine.displayName)",
                                       binary: Self.binaryName(for: engine), body: script)
    }

    /// Asks the engines again if a sign-in or sign-out window was opened since the last check.
    func refreshEngineStatusIfAuthChanged() async {
        guard AppHome.defaults.bool(forKey: Self.authCheckPendingKey) else { return }
        AppHome.defaults.set(false, forKey: Self.authCheckPendingKey)
        await refreshEngineStatus()
    }

    /// Whether this engine is signed in enough that signing out means something.
    func isSignedIn(_ engine: EngineID) -> Bool {
        guard let status = engineStatus[engine] else { return false }
        switch status {
        // A local model has no account, so there is nothing to sign out of.
        case .signedIn(.onThisMac): return false
        case .signedIn, .signedInWithoutModelAccess: return true
        case .signedOut, .notInstalled, .notReady, .unknown: return false
        }
    }

    /// One plain line about an engine's sign-in, for Settings, onboarding and anywhere else that
    /// lists them, with where the CLI was found when that is known.
    ///
    /// Never the CLI's raw output: a failed check reads "Couldn't check", and the error itself
    /// belongs in a tooltip (`engineStatusHelp`).
    static func accountStatusLine(_ status: AuthStatus?, path: String? = nil) -> String {
        guard let status else { return "Checking…" }
        let line: String
        switch status {
        case .signedIn(let method):
            switch method {
            case .subscription: line = "Signed in with your subscription"
            case .apiKey: line = "Signed in with an API key"
            case .onThisMac: line = "Ready. Runs on this Mac"
            }
        case .signedInWithoutModelAccess(let detail):
            line = detail.isEmpty ? "Signed in, but this plan can't run it" : detail
        case .signedOut:
            line = "Not signed in"
        case .notInstalled:
            return "Not installed on this Mac"
        case .notReady(let detail):
            line = detail
        case .unknown:
            line = "Couldn't check"
        }
        guard let path, !path.isEmpty else { return line }
        let home = NSHomeDirectory()
        let shown = path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
        return "\(line). Found at \(shown)"
    }

    // MARK: - Scripts

    private static func binaryName(for engine: EngineID) -> String {
        switch engine {
        case .claude: return ClaudeAdapter().binaryName
        case .codex: return CodexAdapter().binaryName
        case .local: return LocalAdapter().binaryName
        default: return engine.rawValue
        }
    }

    /// Nil for a local model: it has no account, and its first step (pulling a model) downloads
    /// gigabytes, which Bupsy never starts on someone's behalf.
    private static func loginCommand(for engine: EngineID) -> LoginCommand? {
        switch engine {
        case .claude: return ClaudeAdapter().loginCommand()
        case .codex: return CodexAdapter().loginCommand()
        default: return nil
        }
    }

    private static func signInIntro(for engine: EngineID) -> [String] {
        switch engine {
        case .claude:
            return [
                "This is Claude Code's own sign-in. Bupsy never sees what happens here.",
                "Type /login and finish in your browser. Then type /exit and go back to Bupsy.",
            ]
        default:
            return [
                "This is \(engine.displayName)'s own sign-in. Bupsy never sees what happens here.",
                "Finish in your browser, then go back to Bupsy.",
            ]
        }
    }

    /// The sign-out for each engine, guarded by a check that the CLI really has the command.
    ///
    /// Claude Code: `claude auth logout`, listed as the `auth` command in `claude --help`. A build
    /// without it still has `/logout` inside an interactive session, so that is offered instead.
    /// Codex: `codex logout`, listed in `codex --help`.
    private static func signOutScript(for engine: EngineID) -> String? {
        switch engine {
        case .claude:
            return """
            echo 'Signing out of Claude Code with its own command.'
            echo
            if "$CLI" --help 2>/dev/null | grep -Eq '^[[:space:]]+auth([[:space:]]|$)'; then
              "$CLI" auth logout
            else
              echo 'This Claude Code has no sign-out command. Type /logout in the session below, then /exit.'
              echo
              "$CLI"
            fi
            echo
            echo 'Done. You can close this window and go back to Bupsy.'

            """
        case .codex:
            return """
            echo 'Signing out of Codex with its own command.'
            echo
            if "$CLI" --help 2>/dev/null | grep -Eq '^[[:space:]]+logout([[:space:]]|$)'; then
              "$CLI" logout
            else
              echo 'This Codex has no sign-out command. Update Codex, then try again.'
            fi
            echo
            echo 'Done. You can close this window and go back to Bupsy.'

            """
        default:
            return nil
        }
    }

    /// Writes the script beside the Executor installer's and opens it in Terminal.
    ///
    /// The binary is resolved the way runs resolve it (`BinaryResolver`, which falls back to the
    /// person's login shell), off the main thread because that fallback spawns a shell. If it
    /// cannot be found the script uses the bare name, which the login shell may still find, and
    /// otherwise says plainly that the CLI is missing.
    private func openAccountScript(named name: String, binary: String, body: String) async -> Bool {
        let resolved = await Task.detached { try? BinaryResolver.resolve(binary).path }.value
        let cli = resolved ?? binary
        let script = "#!/bin/zsh -l\nclear\nCLI=\(Self.shellQuoted(cli))\n"
            + "if ! command -v \"$CLI\" >/dev/null 2>&1; then\n"
            + "  echo \(Self.shellQuoted("Bupsy couldn't find \(binary) on this Mac. Install it first, then try again."))\n"
            + "  exit 1\n"
            + "fi\n"
            + body
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            accountProblem = "Couldn't open Terminal for this: \(error.localizedDescription)"
            return false
        }
        guard NSWorkspace.shared.open(url) else {
            accountProblem = "Couldn't open Terminal. Open Terminal yourself and run \(binary) to do this."
            return false
        }
        // Only once a window really opened, so a failed attempt does not trigger a check.
        AppHome.defaults.set(true, forKey: Self.authCheckPendingKey)
        return true
    }

    /// Single-quoted for zsh, with any single quote inside closed, escaped and reopened.
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
