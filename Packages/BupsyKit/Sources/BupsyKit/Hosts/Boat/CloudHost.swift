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
        // The id becomes a unit name, file names and part of a shell line, so it is held to
        // characters that mean nothing to systemd or a shell, rather than escaped for each.
        guard Self.isSafeUnitID(trigger.id) else {
            throw HostError.unsupported(
                "routine id '\(trigger.id)' must be letters, digits, '-' or '_'")
        }
        let name = "bupsy-\(trigger.id)"
        let calendar = try Self.onCalendar(fromCron: trigger.cron)
            .map { "OnCalendar=\($0)" }
            .joined(separator: "\n")
        let script = "\(Self.scriptDirectory)/\(name).sh"

        // The command lives in a script file rather than on the ExecStart line. systemd reads
        // ExecStart with its own rules, not a shell's: it expands `$VAR` and `%` specifiers even
        // inside quotes, so a routine whose prompt said "50% done" or "$HOME" ran something
        // other than what it was given. A file is passed to bash byte for byte.
        let service = """
        [Unit]
        Description=bupsy routine \(trigger.id)

        [Service]
        Type=oneshot
        WorkingDirectory=/home/user
        ExecStart=/bin/bash -l \(script)
        """

        let timer = """
        [Unit]
        Description=schedule for bupsy routine \(trigger.id)

        [Timer]
        \(calendar)
        Persistent=true

        [Install]
        WantedBy=timers.target
        """

        try await write("/tmp/\(name).sh", Data((trigger.command + "\n").utf8))
        try await write("/tmp/\(name).service", Data(service.utf8))
        try await write("/tmp/\(name).timer", Data(timer.utf8))

        // Quoted although the id was checked above: the check is what makes it safe, and the
        // quoting is what keeps it safe if the check is ever loosened.
        let q = Self.shellQuote
        let install = """
        sudo mkdir -p \(q(Self.scriptDirectory)) \
          && sudo mv \(q("/tmp/\(name).sh")) \(q(script)) \
          && sudo mv \(q("/tmp/\(name).service")) \(q("/tmp/\(name).timer")) /etc/systemd/system/ \
          && sudo systemctl daemon-reload \
          && sudo systemctl enable --now \(q("\(name).timer"))
        """
        let result = try await api.command(sandboxID, CommandRequest(command: install))
        guard result.success else {
            throw HostError.io("failed to install timer \(name): \(result.stderr ?? "unknown")")
        }
    }

    /// Where trigger scripts are installed on the machine.
    static let scriptDirectory = "/usr/local/lib/bupsy"

    /// Letters, digits, `-` and `_`, and not empty.
    static func isSafeUnitID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_": true
            default: false
            }
        }
    }

    /// Translates the five-field cron we accept into a systemd `OnCalendar` expression.
    ///
    /// Parsed by `CronExpression`, the same parser the Mac schedules with, so the cloud accepts
    /// exactly the schedules the app does and refuses the rest (step syntax, names, out-of-range
    /// values) loudly — a schedule that quietly fires at the wrong time is worse than one that
    /// refuses to install. The translation is then rebuilt from the parsed sets rather than from
    /// the text. Splitting the text on "," and "-" read weekday `1-3,5` as `Mon..Tue..Wed..Fri`,
    /// which systemd rejects, and an hour range `9-17` landed in a field where `-` is the date
    /// separator.
    ///
    /// Returns one `OnCalendar` expression, or two when cron needs a union: with day-of-month
    /// AND weekday both restricted, cron fires on a day matching EITHER ("0 9 1 * 1" is the 1st
    /// and every Monday), while one systemd expression requires both. A timer with two
    /// `OnCalendar=` lines fires on either, which is cron's rule exactly.
    static func onCalendar(fromCron cron: String) throws -> [String] {
        let parsed: CronExpression
        do { parsed = try CronExpression(cron) } catch {
            throw HostError.unsupported("unsupported cron expression '\(cron)': \(error)")
        }
        // cron's own test for "unrestricted": the field starts with `*`.
        let fields = cron.split(separator: " ")
        let dayRestricted = !fields[2].hasPrefix("*")
        let weekdayRestricted = !fields[4].hasPrefix("*")

        let allDays = Set(1...31), allWeekdays = Set(0...6)
        if dayRestricted && weekdayRestricted {
            return [
                calendarExpression(parsed, days: parsed.daysOfMonth, weekdays: allWeekdays),
                calendarExpression(parsed, days: allDays, weekdays: parsed.weekdays),
            ]
        }
        return [calendarExpression(parsed, days: parsed.daysOfMonth, weekdays: parsed.weekdays)]
    }

    private static func calendarExpression(
        _ parsed: CronExpression, days: Set<Int>, weekdays: Set<Int>
    ) -> String {
        let weekdayPart: String
        if weekdays.count == 7 {
            weekdayPart = ""
        } else {
            // systemd's week starts on Monday; cron's Sunday is 0 (7 is folded into it already).
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let mondayFirst = Set(weekdays.map { $0 == 0 ? 6 : $0 - 1 })
            weekdayPart = calendarList(mondayFirst, within: 0...6) { names[$0] } + " "
        }

        let month = calendarList(parsed.months, within: 1...12)
        let day = calendarList(days, within: 1...31)
        let hour = calendarList(parsed.hours, within: 0...23)
        let minute = calendarList(parsed.minutes, within: 0...59)
        return "\(weekdayPart)*-\(month)-\(day) \(hour):\(minute):00"
    }

    /// `*` for every value, otherwise a comma list in which runs of three or more become
    /// `a..b` — systemd's range syntax, which cron's `a-b` is not.
    static func calendarList(
        _ values: Set<Int>, within range: ClosedRange<Int>,
        name: (Int) -> String = { String($0) }
    ) -> String {
        if values == Set(range) { return "*" }
        var parts: [String] = []
        var sorted = values.sorted()[...]
        while let first = sorted.first {
            var last = first
            while sorted.dropFirst().first == last + 1 {
                sorted = sorted.dropFirst()
                last += 1
            }
            sorted = sorted.dropFirst()
            switch last - first {
            case 0: parts.append(name(first))
            case 1: parts += [name(first), name(last)]
            default: parts.append("\(name(first))..\(name(last))")
            }
        }
        return parts.joined(separator: ",")
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
