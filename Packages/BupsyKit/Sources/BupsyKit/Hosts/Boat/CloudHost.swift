import Foundation

/// Runs engines on a machine the user rents from boat with their own key.
///
/// The counterpart to `LocalHost`. The difference that matters to the product is
/// `survivesSleep == true`: work here continues when the Mac is closed, which is the whole
/// reason to pay for a machine at all.
///
/// **Not yet run against the live service.** Written from boat's published API docs; see the
/// note on `BoatAPI`. Known gaps are marked and listed in docs/01-spikes.md rather than hidden.
public struct CloudHost: ExecutionHost {
    public let id: HostID
    public var survivesSleep: Bool { true }

    let api: BoatAPI
    let sandboxID: String

    public init(api: BoatAPI, sandboxID: String) {
        self.api = api
        self.sandboxID = sandboxID
        self.id = .cloud(provider: .boat)
    }

    // MARK: - Running work

    /// Runs the engine and yields its output.
    ///
    /// ⚠️ **Buffered, not streamed.** boat's `POST /commands` is request/response: it returns
    /// once the command exits. So a cloud run produces no output until it finishes, and a long
    /// agent turn will look frozen in the chat UI.
    ///
    /// This is a real gap, not a rounding error, and the fix is already designed: `bupsy-run`
    /// writes canonical events to `~/.bupsy/events/<run>.ndjson` for scheduled work (PLAN.md §4),
    /// and the same file can be tailed with ranged `GET /files` reads for interactive work. That
    /// is deliberately not built here — tailing needs the detached-command API shape confirmed
    /// against the live service first, and guessing it blind is how you get a second rewrite.
    ///
    /// Lines are split and yielded individually so the adapters' normalisers are unchanged
    /// whichever transport eventually feeds them.
    public func spawn(_ invocation: EngineInvocation) async throws
        -> AsyncThrowingStream<HostOutput, Error>
    {
        let command = Self.shellCommand(for: invocation)
        let request = CommandRequest(
            command: command,
            cwd: invocation.workingDirectory?.path ?? "/home/user",
            timeoutSeconds: 900
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await api.command(sandboxID, request)
                    for line in (result.stdout ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
                        continuation.yield(.stdout(String(line)))
                    }
                    for line in (result.stderr ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                    where !line.isEmpty {
                        continuation.yield(.stderr(String(line)))
                    }
                    if result.timedOut == true {
                        continuation.yield(.stderr("command timed out after \(request.timeoutSeconds ?? 0)s"))
                    }
                    continuation.yield(.exit(code: result.exitCode ?? 0))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Builds a single shell line from an invocation.
    ///
    /// Every argument is single-quoted, because a prompt is arbitrary user text heading for a
    /// shell. `stdin` is piped in and the pipe closes on its own — which also keeps Codex from
    /// hanging on an open stdin, the way it does locally.
    static func shellCommand(for invocation: EngineInvocation) -> String {
        let parts = ([invocation.executable] + invocation.arguments).map(shellQuote)
        var command = parts.joined(separator: " ")

        if let stdin = invocation.stdin {
            command = "printf '%s' \(shellQuote(stdin)) | \(command)"
        } else {
            command += " < /dev/null"
        }

        let environment = invocation.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value))" }
        if !environment.isEmpty {
            command = "env " + environment.joined(separator: " ") + " " + command
        }
        return command
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Files

    public func read(_ path: String) async throws -> Data {
        Data(try await api.readFile(sandboxID, path: path).utf8)
    }

    public func write(_ path: String, _ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostError.io("only utf8 writes are supported")
        }
        try await api.writeFile(sandboxID, path: path, content: text)
    }

    // MARK: - Scheduling

    /// Installs a schedule that fires inside the machine.
    ///
    /// **systemd, not cron.** boat's documentation is specific: services enabled with
    /// `systemctl enable --now` restart after resume and fork, while processes started by hand
    /// do not survive a reboot — which a crontab installed at runtime would not either.
    ///
    /// This only does what it promises if the machine is actually running. A stopped sandbox is
    /// a disk image and does not wake for its own timers, so a routine installed here needs the
    /// machine created with `ttlSeconds: nil`. PLAN.md §4 tier 3.
    public func installTrigger(_ trigger: HostTrigger) async throws {
        let name = "bupsy-\(trigger.id)"
        let calendar = try Self.onCalendar(fromCron: trigger.cron)

        let service = """
        [Unit]
        Description=bupsy routine \(trigger.id)

        [Service]
        Type=oneshot
        WorkingDirectory=/home/user
        ExecStart=/bin/bash -lc \(Self.shellQuote(trigger.command))
        """

        let timer = """
        [Unit]
        Description=schedule for bupsy routine \(trigger.id)

        [Timer]
        OnCalendar=\(calendar)
        Persistent=true

        [Install]
        WantedBy=timers.target
        """

        try await write("/tmp/\(name).service", Data(service.utf8))
        try await write("/tmp/\(name).timer", Data(timer.utf8))

        let install = """
        sudo mv /tmp/\(name).service /tmp/\(name).timer /etc/systemd/system/ \
          && sudo systemctl daemon-reload \
          && sudo systemctl enable --now \(name).timer
        """
        let result = try await api.command(sandboxID, CommandRequest(command: install))
        guard result.success else {
            throw HostError.io("failed to install timer \(name): \(result.stderr ?? "unknown")")
        }
    }

    /// Translates the five-field cron we accept into a systemd `OnCalendar` expression.
    ///
    /// Only the subset routines actually use: numbers, `*`, comma lists and `a-b` ranges.
    /// Step syntax (`*/5`) is rejected loudly rather than silently mistranslated — a schedule
    /// that quietly fires at the wrong time is worse than one that refuses to install.
    static func onCalendar(fromCron cron: String) throws -> String {
        let fields = cron.split(separator: " ").map(String.init)
        guard fields.count == 5 else {
            throw HostError.unsupported("expected a five-field cron expression, got '\(cron)'")
        }
        guard !cron.contains("/") else {
            throw HostError.unsupported("step syntax is not supported; use an explicit list")
        }

        let (minute, hour, day, month, weekday) =
            (fields[0], fields[1], fields[2], fields[3], fields[4])

        let days = ["0": "Sun", "1": "Mon", "2": "Tue", "3": "Wed",
                    "4": "Thu", "5": "Fri", "6": "Sat", "7": "Sun"]
        let weekdayPart: String
        if weekday == "*" {
            weekdayPart = ""
        } else {
            let names = weekday
                .split(whereSeparator: { $0 == "," || $0 == "-" })
                .compactMap { days[String($0)] }
            guard names.count > 0 else {
                throw HostError.unsupported("could not read weekday '\(weekday)'")
            }
            weekdayPart = weekday.contains("-")
                ? names.joined(separator: "..") + " "
                : names.joined(separator: ",") + " "
        }

        let pad = { (value: String) in value == "*" ? "*" : value }
        return "\(weekdayPart)*-\(pad(month))-\(pad(day)) \(pad(hour)):\(pad(minute)):00"
    }

    // MARK: - Lifecycle

    public func desktopURL() async throws -> URL? {
        // boat may answer `provisioning: true`, meaning "ask again shortly".
        for attempt in 0..<6 {
            let session = try await api.desktopURL(sandboxID)
            if session.provisioning != true, let string = session.desktopUrl {
                return URL(string: string)
            }
            try await Task.sleep(for: .seconds(1 << attempt))
        }
        return nil
    }

    public func wake() async throws {
        let sandbox = try await api.get(sandboxID)
        guard !sandbox.isRunning else { return }
        _ = try await api.resume(sandboxID)
    }

    public func sleep() async throws {
        _ = try await api.stop(sandboxID)
    }

    public func usage() async throws -> MachineUsage {
        try await api.usage(sandboxID)
    }
}
