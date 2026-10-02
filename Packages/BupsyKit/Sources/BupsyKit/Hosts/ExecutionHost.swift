import Foundation

/// One spawn of an engine binary.
public struct EngineInvocation: Sendable {
    /// Binary name (resolved via BinaryResolver) or an absolute path the user chose.
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL?
    /// Merged over the inherited environment. Must never carry a model credential —
    /// engines read their own credentials from the user's own files.
    public var environment: [String: String]
    /// Written to the process's stdin and closed, for engines that take the prompt that way.
    public var stdin: String?

    public init(executable: String, arguments: [String], workingDirectory: URL? = nil,
                environment: [String: String] = [:], stdin: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdin = stdin
    }
}

/// Raw transport output. Lines, because every engine we support is line-oriented, and
/// stderr stays separate so a diagnostic never gets parsed as a protocol message.
public enum HostOutput: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exit(code: Int32)
}

/// Where work runs. Two implementations: this Mac, and the user's own cloud VM.
///
/// `survivesSleep` is part of the contract because the product promises lid-closed
/// autonomy, and only a cloud host can keep that promise. See PLAN.md §4.
public protocol ExecutionHost: Sendable {
    var id: HostID { get }
    var survivesSleep: Bool { get }

    func spawn(_ invocation: EngineInvocation) async throws -> AsyncThrowingStream<HostOutput, Error>

    func read(_ path: String) async throws -> Data
    func write(_ path: String, _ data: Data) async throws

    /// Installs a schedule that fires on the host itself, so routines survive a sleeping Mac.
    /// Local hosts throw `HostError.unsupported` — the caller is expected to surface that.
    func installTrigger(_ trigger: HostTrigger) async throws

    /// Live desktop for the user to watch or take over. Nil where there is no desktop.
    func desktopURL() async throws -> URL?

    /// Resume a stopped VM. No-op locally.
    func wake() async throws
    /// Snapshot and pause billing. No-op locally.
    func sleep() async throws
}

public struct HostTrigger: Sendable, Equatable {
    public var id: String
    /// Five-field cron expression, interpreted in the host's timezone.
    public var cron: String
    public var command: String
    public init(id: String, cron: String, command: String) {
        self.id = id; self.cron = cron; self.command = command
    }
}

public enum HostError: Error, Sendable, Equatable {
    case unsupported(String)
    case binaryNotFound(String)
    case launchFailed(String)
    case io(String)
}
