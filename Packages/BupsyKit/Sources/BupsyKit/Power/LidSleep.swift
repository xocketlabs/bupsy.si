import Foundation

/// Whether this Mac keeps running with its lid closed, and the switch for it.
///
/// Bots on this Mac only work while it is awake, and closing the lid sleeps it whatever any app
/// asks: the idle-sleep hold a bot takes while working (`PowerAssertion`) does not cover the lid.
/// macOS has one setting that does, `pmset disablesleep`, and it needs an administrator to change.
///
/// Bupsy does not ask for that right itself. Sleepless, a small open-source app made for exactly
/// this, asks once and installs a narrow rule that lets the person flip that one setting, both
/// ways, without a password, and nothing else. Bupsy uses the same rule, so it never holds
/// administrator rights and never shows a password prompt of its own.
public enum LidSleep {
    public enum State: Equatable, Sendable {
        /// The Mac keeps running with the lid closed.
        case survives
        /// It sleeps when the lid closes, as normal.
        case sleeps
    }

    public enum Availability: Equatable, Sendable {
        /// The switch works.
        case ready
        /// Sleepless is installed but has not been given its permission yet.
        case needsSleeplessPermission
        /// Sleepless is not installed.
        case needsSleepless
    }

    public static let sleeplessBundleID = "com.aboudjem.Sleepless"
    public static let sleeplessURL = URL(string: "https://github.com/aboudjem/Sleepless")!
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"

    /// Read from `pmset -g`, which anyone can run.
    public static func state() -> State {
        parseState(run(pmset, ["-g"]).output)
    }

    static func parseState(_ output: String) -> State {
        for line in output.split(separator: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count >= 2, words[0] == "SleepDisabled" { return words[1] == "1" ? .survives : .sleeps }
        }
        return .sleeps
    }

    /// Whether the switch can be flipped without a password, and what to do if not.
    public static func availability(sleeplessInstalled: Bool) -> Availability {
        if canSwitch() { return .ready }
        return sleeplessInstalled ? .needsSleeplessPermission : .needsSleepless
    }

    /// True when `sudo -n` may run both `pmset -a disablesleep` commands, which is the rule
    /// Sleepless installs. `-l` only lists; nothing is run and nothing prompts.
    static func canSwitch() -> Bool {
        let listed = run(sudo, ["-n", "-l"]).output
        return allowsSwitch(listed)
    }

    static func allowsSwitch(_ sudoList: String) -> Bool {
        sudoList.contains("NOPASSWD") && sudoList.contains("pmset -a disablesleep 1")
            && sudoList.contains("pmset -a disablesleep 0")
    }

    /// Flips the setting. Returns the state it ended in, read back rather than assumed.
    @discardableResult
    public static func set(survives: Bool) -> State {
        _ = run(sudo, ["-n", pmset, "-a", "disablesleep", survives ? "1" : "0"])
        return state()
    }

    static func run(_ command: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
