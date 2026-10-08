import Foundation

/// What Tailscale says about this Mac.
public struct TailscaleStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// No `tailscale` command anywhere we look.
        case notInstalled
        /// Installed, but not signed in or not connected.
        case notConnected(String)
        case connected
    }

    public var state: State
    /// This Mac's name on the person's tailnet, e.g. `vanshs-macbook-pro.taild5f9c6.ts.net`.
    public var dnsName: String?

    public init(state: State, dnsName: String? = nil) {
        self.state = state; self.dnsName = dnsName
    }
}

/// Talks to the Tailscale the person installed, through its own command line.
///
/// Bupsy never runs a network of its own: Tailscale already connects the person's devices to
/// each other privately, and `tailscale serve` hands a local server to those devices only, with
/// HTTPS and Tailscale's own sign-in. Bupsy asks for exactly one thing, its own HTTPS port, and
/// leaves everything else the person serves (or funnels to the internet) alone.
public enum Tailscale {
    /// Not 443, which is the one people use for their own things.
    public static let httpsPort = 8443

    /// Where the command line lives: the Mac app's own copy first, then a Homebrew or manual
    /// install.
    public static func commandPath() -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func status() async -> TailscaleStatus {
        guard let command = commandPath() else { return TailscaleStatus(state: .notInstalled) }
        guard let result = try? await run(command, ["status", "--json"], timeout: 10) else {
            return TailscaleStatus(state: .notConnected("Tailscale didn't answer. Is it running?"))
        }
        return parseStatus(result.output)
    }

    static func parseStatus(_ json: String) -> TailscaleStatus {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return TailscaleStatus(state: .notConnected("Tailscale isn't running.")) }
        let backend = object["BackendState"] as? String ?? ""
        let dns = ((object["Self"] as? [String: Any])?["DNSName"] as? String)
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        switch backend {
        case "Running":
            return TailscaleStatus(state: .connected, dnsName: dns)
        case "NeedsLogin", "NoState":
            return TailscaleStatus(state: .notConnected("Sign in to Tailscale on this Mac."), dnsName: dns)
        case "Stopped":
            return TailscaleStatus(state: .notConnected("Tailscale is turned off. Turn it on from its menu."), dnsName: dns)
        default:
            return TailscaleStatus(state: .notConnected("Tailscale isn't connected yet."), dnsName: dns)
        }
    }

    /// Another Mac on the person's tailnet, offered when linking Macs.
    public struct Peer: Equatable, Sendable, Identifiable {
        public let name: String
        /// Its Tailscale name, which is what Bupsy's address is built from.
        public let dnsName: String
        public let online: Bool
        public var id: String { dnsName }
    }

    /// The person's other Macs on their tailnet. Only Macs: Bupsy runs on nothing else yet, and
    /// Tailscale's own relay nodes, servers and phones would be noise in the list.
    public static func macs() async -> [Peer] {
        guard let command = commandPath(),
              let result = try? await run(command, ["status", "--json"], timeout: 10) else { return [] }
        return parsePeers(result.output)
    }

    static func parsePeers(_ json: String) -> [Peer] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let peers = object["Peer"] as? [String: [String: Any]] else { return [] }
        return peers.values.compactMap { peer -> Peer? in
            guard peer["OS"] as? String == "macOS",
                  let dns = (peer["DNSName"] as? String).map({ $0.hasSuffix(".") ? String($0.dropLast()) : $0 }),
                  !dns.isEmpty else { return nil }
            return Peer(name: peer["HostName"] as? String ?? dns, dnsName: dns, online: peer["Online"] as? Bool ?? false)
        }
        .sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
    }

    public enum ServeError: Error, LocalizedError, Equatable {
        case notInstalled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "Tailscale isn't installed on this Mac."
            case .failed(let message): message
            }
        }
    }

    /// Hands `localPort` to the person's own devices at `https://<this Mac>:8443`. Serve, never
    /// Funnel: nothing here is ever offered to the internet.
    public static func serve(localPort: UInt16) async throws {
        guard let command = commandPath() else { throw ServeError.notInstalled }
        let result = try await run(command, ["serve", "--bg", "--yes", "--https=\(httpsPort)",
                                             "http://127.0.0.1:\(localPort)"], timeout: 30)
        guard result.status == 0 else {
            throw ServeError.failed(explain(result.output))
        }
    }

    /// Takes Bupsy's port back off the tailnet. Only that port: anything else served stays.
    public static func stopServing() async {
        guard let command = commandPath() else { return }
        _ = try? await run(command, ["serve", "--https=\(httpsPort)", "off"], timeout: 15)
    }

    /// Tailscale's own words, made into a next step where we can tell what it is.
    static func explain(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if lowered.contains("https") && (lowered.contains("not enabled") || lowered.contains("enable")) {
            // Tailscale prints the admin page that turns HTTPS certificates on; keep its link.
            let link = text.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("https://login.tailscale.com") }
            return "Turn on HTTPS for your tailnet first" + (link.map { ": \($0)" } ?? " in the Tailscale admin console (DNS → HTTPS Certificates).")
        }
        if lowered.contains("serve") && lowered.contains("not enabled") {
            return "Tailscale Serve isn't enabled for your tailnet. Enable it in the Tailscale admin console."
        }
        return text.isEmpty ? "Tailscale couldn't share Bupsy." : text
    }

    // MARK: - Running the command

    struct Result { let status: Int32; let output: String }

    /// Runs the command with a deadline. Output is read as it arrives, not at the end: a status
    /// with many devices is more than a pipe holds, and a process blocked writing it would never
    /// finish.
    /// The Mac app's binary is both the app and the command line, and picks by how it was started:
    /// from a terminal (TERM or SHLVL set) it answers as the command line; from anything else it
    /// tries to open the app and prints nothing useful. Bupsy opened from Finder, the Dock or at
    /// login has neither, so it said "Tailscale isn't running" while Tailscale was running. This
    /// is Tailscale's own switch for running it as the command line.
    static func commandEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["TAILSCALE_BE_CLI"] = "1"
        return environment
    }

    static func run(_ command: String, _ arguments: [String], timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            process.environment = commandEnvironment(ProcessInfo.processInfo.environment)
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let output = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            DispatchQueue.global().async {
                let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
                if timedOut { process.terminate() }
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                if timedOut {
                    continuation.resume(throwing: ServeError.failed("Tailscale took too long to answer."))
                } else {
                    continuation.resume(returning: Result(status: process.terminationStatus, output: output.text))
                }
            }
        }
    }
}

/// Output gathered from a pipe's handler thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data) {
        lock.lock(); data.append(more); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
