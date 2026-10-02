import Foundation
import Testing
@testable import BupsyKit

/// These spawn real processes. They are the only tests here that touch the OS, and they exist
/// because the bugs they catch are invisible to a unit test over fixtures.
@Suite("LocalHost process supervision")
struct LocalHostTests {
    let host = LocalHost()

    /// Races a stream against a deadline so a hang fails the test instead of wedging the suite.
    private func collect(
        _ invocation: EngineInvocation,
        deadline: Duration = .seconds(10)
    ) async throws -> [HostOutput] {
        try await withThrowingTaskGroup(of: [HostOutput]?.self) { group in
            let stream = try await host.spawn(invocation)
            group.addTask {
                var collected: [HostOutput] = []
                for try await output in stream { collected.append(output) }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            guard let first = try await group.next() else { return [] }
            group.cancelAll()
            guard let collected = first else {
                Issue.record("spawn did not finish within \(deadline) — the process hung")
                return []
            }
            return collected
        }
    }

    /// The regression test for a hang found in M0. `codex`, given a prompt argument and an open
    /// stdin, waits for stdin to close so it can append it as a `<stdin>` block — and waits
    /// forever if nobody closes it.
    ///
    /// `cat` is the perfect probe: with stdin closed it exits immediately; with stdin left open
    /// it blocks indefinitely. If this test ever times out, `ProcessBox` stopped closing stdin
    /// and every Codex run in the product is hanging.
    @Test("closes stdin, so a process that reads it still exits")
    func closesStdin() async throws {
        let output = try await collect(EngineInvocation(executable: "cat", arguments: []))
        #expect(output.contains(.exit(code: 0)))
    }

    @Test("writes provided stdin through before closing it")
    func forwardsStdin() async throws {
        let output = try await collect(
            EngineInvocation(executable: "cat", arguments: [], stdin: "hello from bupsy\n"))
        #expect(output.contains(.stdout("hello from bupsy")))
        #expect(output.contains(.exit(code: 0)))
    }

    @Test("keeps stderr separate from stdout, so diagnostics are never parsed as protocol")
    func separatesStreams() async throws {
        let output = try await collect(EngineInvocation(
            executable: "sh", arguments: ["-c", "echo out; echo err 1>&2"]))
        #expect(output.contains(.stdout("out")))
        #expect(output.contains(.stderr("err")))
    }

    /// Both pipes are drained concurrently. Draining one at a time risks the other's buffer
    /// filling and deadlocking a chatty engine — which is precisely what agent CLIs are.
    @Test("drains both pipes concurrently without deadlocking on a chatty process")
    func drainsConcurrently() async throws {
        let output = try await collect(EngineInvocation(
            executable: "sh",
            arguments: ["-c", "for i in $(seq 1 400); do echo out-$i; echo err-$i 1>&2; done"]))

        let stdout = output.filter { if case .stdout = $0 { true } else { false } }
        let stderr = output.filter { if case .stderr = $0 { true } else { false } }
        #expect(stdout.count == 400)
        #expect(stderr.count == 400)
        #expect(output.contains(.exit(code: 0)))
    }

    @Test("reports a non-zero exit rather than swallowing it")
    func reportsExitCode() async throws {
        let output = try await collect(EngineInvocation(executable: "sh", arguments: ["-c", "exit 3"]))
        #expect(output.contains(.exit(code: 3)))
    }

    @Test("a missing binary throws instead of hanging")
    func missingBinary() async {
        await #expect(throws: HostError.self) {
            _ = try await host.spawn(
                EngineInvocation(executable: "definitely-not-a-real-binary-xyz", arguments: []))
        }
    }

    /// The trap that made `BinaryResolver` necessary: a GUI app inherits launchd's minimal
    /// environment, and `claude` installs to `~/.local/bin`, which is on none of the default
    /// system paths.
    @Test("resolves an absolute path and rejects one that is not executable")
    func resolvesAbsolutePaths() throws {
        #expect(try BinaryResolver.resolve("/bin/sh").path == "/bin/sh")
        #expect(throws: HostError.self) {
            try BinaryResolver.resolve("/definitely/not/here")
        }
    }
}
