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
        environment.merge(invocation.environment) { _, new in new }
        process.environment = environment
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

                    process.waitUntilExit()
                    continuation.yield(.exit(code: process.terminationStatus))
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
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { return }
                emit(line)
            }
        } catch {
            // A closed pipe at exit is normal; a real read error shows up in the exit code.
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
