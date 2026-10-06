import Foundation
import Testing
@testable import BupsyKit

/// A host that answers every spawn the same way, so an adapter's status check can be driven
/// without a real CLI on the machine.
private struct ScriptedHost: ExecutionHost {
    enum Reply: Sendable {
        /// What LocalHost does when the binary is on none of the paths it searches.
        case missingBinary
        case output([HostOutput])
    }

    let reply: Reply
    let id: HostID = .local
    var survivesSleep: Bool { false }

    func spawn(_ invocation: EngineInvocation) async throws -> AsyncThrowingStream<HostOutput, Error> {
        switch reply {
        case .missingBinary:
            throw HostError.binaryNotFound(invocation.executable)
        case .output(let lines):
            return AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        }
    }

    func read(_ path: String) async throws -> Data { Data() }
    func write(_ path: String, _ data: Data) async throws {}
    func installTrigger(_ trigger: HostTrigger) async throws {}
    func desktopURL() async throws -> URL? { nil }
    func wake() async throws {}
    func sleep() async throws {}
}

/// "Not installed" and "signed out" need different fixes (install it, or sign in), so the status
/// check has to tell them apart rather than handing the UI a raw error.
@Suite("Engine status: not installed vs signed out")
struct AuthStatusTests {
    @Test("a missing Claude Code binary reads as not installed")
    func claudeMissing() async {
        let status = await ClaudeAdapter().authStatus(on: ScriptedHost(reply: .missingBinary))
        #expect(status == .notInstalled)
    }

    @Test("a missing Codex binary reads as not installed")
    func codexMissing() async {
        let status = await CodexAdapter().authStatus(on: ScriptedHost(reply: .missingBinary))
        #expect(status == .notInstalled)
    }

    @Test("the shell's command-not-found exit reads as not installed")
    func commandNotFoundExit() async {
        let host = ScriptedHost(reply: .output([.stderr("zsh: command not found: codex"), .exit(code: 127)]))
        #expect(await CodexAdapter().authStatus(on: host) == .notInstalled)
        #expect(await ClaudeAdapter().authStatus(on: host) == .notInstalled)
    }

    @Test("an installed but signed-out Codex still reads as signed out")
    func codexSignedOut() async {
        let host = ScriptedHost(reply: .output([.stdout("Not logged in"), .exit(code: 1)]))
        #expect(await CodexAdapter().authStatus(on: host) == .signedOut)
    }

    @Test("not installed is never usable")
    func notUsable() {
        #expect(!AuthStatus.notInstalled.isUsable)
    }
}
