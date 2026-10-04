#if os(macOS)
import Foundation

/// Installs a user LaunchAgent so routines run with bupsy closed.
///
/// macOS only, and unavoidably so: launchd has no equivalent elsewhere. A port needs its own
/// scheduler behind the same idea — Task Scheduler on Windows, a systemd user timer on Linux —
/// which is why `RoutineScheduler` decides *what is due* and this only installs it.
///
/// Chosen after `pmset schedule wake` turned out to need root. A user agent needs no
/// authorisation at all, and launchd starts the app when a routine is due — verified by
/// installing one and watching it fire three times on schedule.
///
/// What it does **not** do is wake the Mac. launchd runs a `StartCalendarInterval` job whose time
/// passed during sleep once on wake, so a 7am briefing arrives when the lid opens rather than
/// being lost. PLAN.md §4 tier 2 states that limit in those words, and so does the UI.
public enum LaunchAgent {
    public static let label = "si.bupsy.routines"

    public static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Installs or replaces the agent covering every launchAgent-tier routine.
    ///
    /// One agent for all of them rather than one each: launchd is a shared, user-visible resource,
    /// and leaving a trail of orphaned `si.bupsy.routine.<uuid>` jobs behind on uninstall would be
    /// rude. The app works out which routine is actually due when it starts.
    public static func install(
        intervals: [[String: Int]],
        appPath: String,
        fileManager: FileManager = .default
    ) throws {
        guard !intervals.isEmpty else { try uninstall(); return }

        let directory = plistURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            // `open -gj` launches the app without stealing focus or showing a window. A routine
            // firing while someone is working should not pull them out of what they are doing.
            "ProgramArguments": ["/usr/bin/open", "-gj", "-a", appPath, "--args", "--run-due-routines"],
            "StartCalendarInterval": intervals,
            "RunAtLoad": false,
            "ProcessType": "Background",
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // bootout first: launchd will not reload a changed plist under a label it already knows.
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    public static func uninstall(fileManager: FileManager = .default) throws {
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? fileManager.removeItem(at: plistURL)
    }

    public static func isInstalled(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    /// The plist contents, exposed for tests so the shape can be checked without touching
    /// the real `~/Library/LaunchAgents`.
    public static func plist(intervals: [[String: Int]], appPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-gj", "-a", appPath, "--args", "--run-due-routines"],
            "StartCalendarInterval": intervals,
            "RunAtLoad": false,
            "ProcessType": "Background",
        ]
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let waitForExit = try process.launchForWaiting()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        waitForExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw HostError.io("launchctl \(arguments.joined(separator: " ")): \(output)")
        }
        return output
    }
}
#endif
