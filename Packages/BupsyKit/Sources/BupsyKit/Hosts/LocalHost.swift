import Foundation

/// Runs engines as subprocesses on this Mac, under the user's own logins.
///
/// We spawn vendor binaries; we never read their credentials. The engine finds its own
/// sign-in in `~/.claude`, `~/.codex` and so on — files owned by the user and the CLI, which
/// this process never opens. See docs/00-compliance-and-auth.md.
///
/// Note `survivesSleep == false`: anything scheduled here stops when the Mac sleeps. Routines
/// that must survive a closed lid belong on a cloud host.
public struct LocalHost: ExecutionHost {
    public let id: HostID = .local
    public var survivesSleep: Bool { false }

    public init() {}

    public func spawn(_ invocation: EngineInvocation) async throws
        -> AsyncThrowingStream<HostOutput, Error>
    {
        let executable = try BinaryResolver.resolve(invocation.executable)
        let box = ProcessBox(executable: executable, invocation: invocation)
        return box.start()
    }

    public func read(_ path: String) async throws -> Data {
        do { return try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw HostError.io("read \(path): \(error.localizedDescription)") }
    }

    public func write(_ path: String, _ data: Data) async throws {
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { throw HostError.io("write \(path): \(error.localizedDescription)") }
    }

    public func installTrigger(_ trigger: HostTrigger) async throws {
        // Deliberately unsupported. A local schedule would silently not fire while the Mac
        // sleeps, which is exactly the failure the product promises to avoid. The caller
        // surfaces this as "move this routine to the cloud to run with the lid closed".
        throw HostError.unsupported("local host cannot hold a schedule that survives sleep")
    }

    public func desktopURL() async throws -> URL? { nil }
    public func wake() async throws {}
    public func sleep() async throws {}
}

/// Owns one subprocess and its pipes.
///
/// `@unchecked Sendable` is a deliberate, contained lie: `Process` and `Pipe` are not Sendable,
/// but this box is created, started and finished on one task, and every mutable field is
/// guarded by `lock`. Keeping the unsafety here means nothing above it needs to think about it.
private final class ProcessBox: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let invocation: EngineInvocation
    private let lock = NSLock()
    private var finished = false
    private let exitStatus = ExitStatus()

    init(executable: URL, invocation: EngineInvocation) {
        self.invocation = invocation
        process.executableURL = executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        var environment = ProcessInfo.processInfo.environment
        // Engines are better behaved when they know they are not on a terminal.
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        #if !os(Windows)
        // So whatever the engine starts — MCP servers above all — is found the way it would be
        // in the person's own terminal. See `BinaryResolver.searchPath`.
        environment["PATH"] = BinaryResolver.searchPath(current: environment["PATH"])
        #endif
        environment.merge(invocation.environment) { _, new in new }
        process.environment = environment
        // Set before the process starts, so an exit can never be missed.
        let exitStatus = self.exitStatus
        process.terminationHandler = { exitStatus.set($0.terminationStatus) }
    }

    func start() -> AsyncThrowingStream<HostOutput, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task { [self] in
                do {
                    try process.run()

                    if let stdin = invocation.stdin {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                    }
                    try? stdinPipe.fileHandleForWriting.close()

                    // Both streams are drained concurrently. Draining only one risks the other's
                    // pipe buffer filling and deadlocking a chatty engine.
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { [self] in
                            await drain(stdoutPipe) { continuation.yield(.stdout($0)) }
                        }
                        group.addTask { [self] in
                            await drain(stderrPipe) { continuation.yield(.stderr($0)) }
                        }
                    }

                    // Not waitUntilExit(): it spins the *current* run loop, and on a concurrency
                    // pool thread there is none to deliver the exit — so it could wait forever
                    // for a process that had already gone, leaving a bot "working" indefinitely.
                    // It hung CI for an hour before this was found.
                    let code = await exitStatus.wait()
                    continuation.yield(.exit(code: code))
                    finish(continuation, throwing: nil)
                } catch {
                    finish(continuation, throwing: HostError.launchFailed(error.localizedDescription))
                }
            }

            continuation.onTermination = { [self] _ in
                pump.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func drain(_ pipe: Pipe, emit: @Sendable (String) -> Void) async {
        // LineReader rather than FileHandle.bytes.lines: the latter is Apple-only and does not
        // exist in corelibs-foundation, which the Linux CI job found. One implementation on every
        // platform is worth more here than a platform branch — this is the code that drains every
        // agent process, so it should be the same code everywhere it runs.
        for await line in LineReader.lines(of: pipe.fileHandleForReading) {
            if Task.isCancelled { return }
            emit(line)
        }
    }

    private func finish(
        _ continuation: AsyncThrowingStream<HostOutput, Error>.Continuation,
        throwing error: Error?
    ) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        continuation.finish(throwing: error)
    }
}

/// A process's exit status, delivered once by its termination handler and awaited by the reader.
final class ExitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func set(_ value: Int32) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: value)
        } else {
            status = value
            lock.unlock()
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
