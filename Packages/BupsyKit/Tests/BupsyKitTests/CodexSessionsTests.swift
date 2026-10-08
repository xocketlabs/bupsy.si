import Foundation
import Testing
@testable import BupsyKit

@Suite("Codex's own usage records")
struct CodexSessionsTests {
    static let record = #"""
    {"timestamp":"2026-09-08T22:22:52.698Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":153212,"cached_input_tokens":121728,"output_tokens":959},"last_token_usage":{"input_tokens":48906,"cached_input_tokens":42752,"output_tokens":415},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1789481274},"secondary":{"used_percent":40.0,"window_minutes":300,"resets_at":1789400000}}}}
    """#

    @Test("reads the last call's context and the window, not the turn's totals")
    func context() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
        let day = folder.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let earlier = Self.record.replacingOccurrences(of: "48906", with: "1000")
        try (earlier + "\n" + Self.record + "\n{\"type\":\"response_item\"}\n")
            .write(to: day.appendingPathComponent("rollout-2026-10-09T00-00-00-abc-123.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folder) }

        let reading = try #require(CodexSessions.latest(conversation: "abc-123", in: folder, now: now))
        #expect(reading.context == ContextUse(cachedTokens: 42_752, newTokens: 6_154, replyTokens: 415, window: 258_400))
        #expect(reading.limits?.windows["seven_day"]?.utilization == 0.03)
        #expect(reading.limits?.windows["five_hour"]?.utilization == 0.4)
        #expect(CodexSessions.latest(conversation: "other", in: folder, now: now) == nil)
        #expect(CodexSessions.latest(conversation: "../abc-123", in: folder, now: now) == nil)
    }

    @Test("names windows the way Claude's are named")
    func windowNames() {
        #expect(CodexSessions.windowName(minutes: 300) == "five_hour")
        #expect(CodexSessions.windowName(minutes: 10_080) == "seven_day")
        #expect(CodexSessions.windowName(minutes: 2_880) == "2_day")
    }
}
