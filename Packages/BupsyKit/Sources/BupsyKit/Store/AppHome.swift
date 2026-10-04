import Foundation

/// Where bupsy keeps its data: `~/Library/Application Support/si.bupsy`, or the folder named by the
/// `BUPSY_HOME` environment variable.
///
/// The override exists so the app can be run against a throwaway home — a first-launch walkthrough,
/// screenshots, a bug reproduction — without going anywhere near someone's real bots and history.
/// Everything bupsy writes follows it: the database, the outbox, bots' own folders, preferences.
public enum AppHome {
    /// The override, if set and non-empty.
    public static var override: URL? {
        guard let path = ProcessInfo.processInfo.environment["BUPSY_HOME"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// True when running against an override rather than the real home.
    public static var isSandboxed: Bool { override != nil }

    /// The folder everything lives in, created if needed.
    public static var directory: URL {
        let base = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first.map { $0.appendingPathComponent("si.bupsy", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("si.bupsy", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Preferences: the app's own defaults normally, a separate suite under an override so a
    /// throwaway run neither reads nor changes the real ones.
    public static var defaults: UserDefaults {
        guard let override else { return .standard }
        // A stable hash of the path — `hashValue` is reseeded every launch, which would hand each
        // run fresh, empty preferences.
        let stable = override.path.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return UserDefaults(suiteName: "si.bupsy.home." + String(stable, radix: 36)) ?? .standard
    }
}
