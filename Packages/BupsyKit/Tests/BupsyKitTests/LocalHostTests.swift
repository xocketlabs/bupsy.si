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

    /// `read(upToCount: 4096)` waited for a full 4 KB or the end of the pipe, so a short line sat
    /// unseen until the engine wrote more or exited — a live run that looked frozen.
    @Test("a line arrives as soon as it is written, not when the process exits")
    func linesArriveLive() async throws {
        let stream = try await host.spawn(EngineInvocation(
            executable: "sh", arguments: ["-c", "echo early; exec sleep 10"]))
        let clock = ContinuousClock()
        let started = clock.now
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == .stdout("early"))
        #expect(clock.now - started < .seconds(5), "the line waited for the process to exit")
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

    /// The standard system locations, including the ones a login shell cannot help with because
    /// the name is also a builtin.
    @Test("finds binaries in the usual system folders")
    func findsSystemBinaries() throws {
        for name in ["sh", "cat", "pwd", "env"] {
            let resolved = try BinaryResolver.resolve(name)
            #expect(FileManager.default.isExecutableFile(atPath: resolved.path),
                    "\(name) resolved to something that is not executable")
        }
    }
}

@Suite("Working folder")
struct WorkingDirectoryTests {
    /// The feature that turns a bot from a chat window into a tool: it runs *somewhere*. Before
    /// this, every bot ran in whatever directory the app happened to launch from and could not
    /// see any of the user's work.
    @Test("a run happens in the folder it was given")
    func runsInTheGivenFolder() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bupsy-wd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // `sh -c pwd` rather than `pwd`: the latter is also a shell builtin, so resolving it
        // through a login shell answers with the builtin's name and no path — which is how this
        // test found that /bin was missing from the resolver's search list.
        var output: [String] = []
        for try await chunk in try await LocalHost().spawn(EngineInvocation(
            executable: "sh", arguments: ["-c", "pwd"], workingDirectory: folder))
        {
            if case .stdout(let line) = chunk { output.append(line) }
        }

        // /var and /private/var are the same place; compare what the filesystem resolves to.
        let reported = URL(fileURLWithPath: output.first ?? "").resolvingSymlinksInPath().path
        #expect(reported == folder.resolvingSymlinksInPath().path)
    }

    @Test("the folder reaches the invocation from a run request")
    func folderReachesInvocation() {
        let folder = URL(fileURLWithPath: "/tmp/somewhere")
        for adapter: any EngineAdapter in [ClaudeAdapter(), CodexAdapter()] {
            let invocation = adapter.invocation(
                for: RunRequest(prompt: "x", workingDirectory: folder))
            #expect(invocation.workingDirectory == folder, "\(adapter.id) dropped the folder")
        }
    }
}

@Suite("Line reading")
struct LineReaderTests {
    /// Engine output is line-delimited JSON, so a line split across two reads would be
    /// unparseable — the kind of failure that only shows up under load, on a long reply.
    @Test("reassembles a line split across chunks")
    func reassemblesSplitLines() {
        var reader = LineReader(FileHandle.nullDevice)
        #expect(reader.take(Data(#"{"type":"te"#.utf8)).isEmpty)
        #expect(reader.take(Data("xt\"}\n".utf8)) == [#"{"type":"text"}"#])
    }

    @Test("returns every complete line in one chunk")
    func multipleLinesInAChunk() {
        var reader = LineReader(FileHandle.nullDevice)
        #expect(reader.take(Data("a\nb\nc\n".utf8)) == ["a", "b", "c"])
    }

    /// A process that exits without a trailing newline still said something.
    @Test("flushes a final line with no newline")
    func flushesTrailingLine() {
        var reader = LineReader(FileHandle.nullDevice)
        #expect(reader.take(Data("done".utf8)).isEmpty)
        #expect(reader.flush() == ["done"])
        #expect(reader.flush().isEmpty, "flushing twice must not repeat it")
    }

    @Test("strips carriage returns, so Windows line endings read the same")
    func stripsCarriageReturns() {
        var reader = LineReader(FileHandle.nullDevice)
        #expect(reader.take(Data("a\r\nb\r\n".utf8)) == ["a", "b"])
    }

    @Test("an empty line is a line, not a dropped one")
    func keepsEmptyLines() {
        var reader = LineReader(FileHandle.nullDevice)
        #expect(reader.take(Data("a\n\nb\n".utf8)) == ["a", "", "b"])
    }

    /// A line built up over many chunks used to be rescanned from its start on every chunk,
    /// so one long line cost quadratic time. 4 MB in 4 KB reads is a thousand chunks.
    @Test("a long line built from many chunks is reassembled whole")
    func longLineAcrossManyChunks() {
        var reader = LineReader(FileHandle.nullDevice)
        let piece = Data(repeating: UInt8(ascii: "x"), count: 4096)
        for _ in 0..<1024 { #expect(reader.take(piece).isEmpty) }
        let lines = reader.take(Data("y\nnext\n".utf8))
        #expect(lines.count == 2)
        #expect(lines.first?.count == 4096 * 1024 + 1)
        #expect(lines.last == "next")
    }

    /// Past the limit a line is dropped and flagged, not held: a process that never writes a
    /// newline would otherwise grow the buffer until the app ran out of memory.
    @Test("a line past the limit is dropped and flagged, and reading carries on")
    func capsLineLength() {
        var reader = LineReader(FileHandle.nullDevice, maximumLineLength: 10)
        #expect(reader.take(Data("short\n".utf8)) == ["short"])
        #expect(reader.take(Data("0123456789AB".utf8)) == [LineReader.truncatedLineMarker])
        // The rest of the runaway line is discarded up to its newline, then normal service.
        #expect(reader.take(Data("more junk".utf8)).isEmpty)
        #expect(reader.take(Data("tail\nok\n".utf8)) == ["ok"])
        // Over-long within a single chunk too.
        #expect(reader.take(Data("0123456789ABCDEF\nfine\n".utf8))
            == [LineReader.truncatedLineMarker, "fine"])
        #expect(reader.flush().isEmpty)
    }
}

@Suite("Stopping a run")
struct ProcessStopTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bupsy-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Waits for a condition with a deadline, so a regression fails instead of hanging.
    private func eventually(
        within: Duration = .seconds(5), _ condition: () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + within
        while clock.now < end {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Stop pressed in the gap between `spawn` and the child actually starting. The termination
    /// handler found nothing running, and the pump then launched the engine anyway — a bot the
    /// person had stopped, working on with nobody reading it.
    @Test("a stream cancelled before launch never runs the process")
    func cancelledBeforeLaunchNeverRuns() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("ran").path

        let box = ProcessBox(
            executable: URL(fileURLWithPath: "/bin/sh"),
            invocation: EngineInvocation(
                executable: "/bin/sh", arguments: ["-c", "touch '\(marker)'; exec /bin/sleep 30"]))
        let (gate, open) = AsyncStream<Void>.makeStream()
        box.beforeLaunch = { for await _ in gate { return } }

        let stream = box.start()
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
        _ = try? await consumer.value
        open.yield()

        #expect(try await eventually { box.launch != .pending })
        #expect(box.launch == .skipped)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker), "the process ran after Stop")
    }

    /// Stop must reach what the engine started — the shell commands and servers that do the
    /// actual work — and must not be defeated by one that ignores SIGTERM.
    @Test("stopping a run kills its whole process group, escalating past an ignored SIGTERM")
    func stopKillsTheGroup() async throws {
        let box = ProcessBox(
            executable: URL(fileURLWithPath: "/bin/sh"),
            invocation: EngineInvocation(
                executable: "/bin/sh",
                // Ignored signals survive exec, so the grandchild shrugs off SIGTERM too.
                arguments: ["-c", "trap '' TERM; /bin/sleep 30 & echo $!; wait"]),
            killGrace: .milliseconds(300))

        let stream = box.start()
        let (pids, found) = AsyncStream<Int32>.makeStream()
        let consumer = Task {
            for try await output in stream {
                if case .stdout(let line) = output, let pid = Int32(line) { found.yield(pid) }
            }
        }
        var iterator = pids.makeAsyncIterator()
        let grandchild = try #require(await iterator.next())
        let engine = box.processIdentifier
        #expect(isAlive(grandchild))

        consumer.cancel()

        #expect(try await eventually { !isAlive(engine) }, "the engine survived Stop")
        #expect(try await eventually { !isAlive(grandchild) }, "a tool it started survived Stop")
    }
}
