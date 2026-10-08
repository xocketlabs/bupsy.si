import Foundation

/// What Codex wrote down about a turn that `codex exec --json` does not say: how full the context
/// window was, how big the window is, and the plan's usage limits.
///
/// `exec` reports a turn's usage as totals across every model call in it, with no window size, so
/// a Codex bot had no context meter at all. Codex records each call's own figures in the
/// conversation's file under `~/.codex/sessions/<year>/<month>/<day>/rollout-…-<id>.jsonl`, as
/// `token_count` events. Only those files are read, and only their ends: never the sign-in.
public enum CodexSessions {
    public static var sessionsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public struct Reading: Sendable, Equatable {
        public var context: ContextUse?
        public var limits: RateLimit?
    }

    /// The latest figures for a conversation, or nil when its file or a usage record isn't found.
    public static func latest(conversation id: String, in folder: URL = sessionsFolder, now: Date = Date()) -> Reading? {
        guard let file = file(for: id, in: folder, now: now) else { return nil }
        // Newest last; the last usage record is the turn that just ended.
        guard let record = ClaudeSessions.records(tailOf: file, bytes: 512 * 1024).last(where: {
            ($0["payload"] as? [String: Any])?["type"] as? String == "token_count"
        }), let payload = record["payload"] as? [String: Any] else { return nil }
        return reading(payload)
    }

    static func reading(_ payload: [String: Any]) -> Reading {
        var reading = Reading()
        if let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
            func int(_ key: String) -> Int { (last[key] as? NSNumber)?.intValue ?? 0 }
            // input_tokens includes the cached part; the meter shows them apart.
            let input = int("input_tokens"), cached = min(int("cached_input_tokens"), input)
            reading.context = ContextUse(cachedTokens: cached, newTokens: input - cached,
                                         replyTokens: int("output_tokens"),
                                         window: (info["model_context_window"] as? NSNumber)?.intValue)
        }
        if let limits = payload["rate_limits"] as? [String: Any] {
            var windows: [String: RateLimit.Window] = [:]
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any],
                      let used = (window["used_percent"] as? NSNumber)?.doubleValue,
                      let minutes = (window["window_minutes"] as? NSNumber)?.intValue else { continue }
                let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows[windowName(minutes: minutes)] = RateLimit.Window(utilization: used / 100, resetsAt: resets)
            }
            if !windows.isEmpty { reading.limits = RateLimit(windows: windows) }
        }
        return reading
    }

    /// The same names Claude's limits use where the length matches, so they read the same.
    static func windowName(minutes: Int) -> String {
        switch minutes {
        case 300: "five_hour"
        case 10_080: "seven_day"
        case 1_440: "one_day"
        default: minutes % 1_440 == 0 ? "\(minutes / 1_440)_day" : "\(minutes)_minute"
        }
    }

    /// Codex files a conversation under the day it started, so the last few days are looked in
    /// first; a conversation older than that is found by walking the whole folder.
    static func file(for id: String, in folder: URL, now: Date) -> URL? {
        guard !id.isEmpty, !id.contains("/") else { return nil }
        let suffix = "-\(id).jsonl"
        let calendar = Calendar(identifier: .gregorian)
        for daysBack in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = folder.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            if let match = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasSuffix(suffix) }) {
                return dir.appendingPathComponent(match)
            }
        }
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = all?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix(suffix) { return url }
        }
        return nil
    }
}
