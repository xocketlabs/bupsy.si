import Foundation
import Testing
@testable import BupsyKit

/// Takes real power assertions. They are released immediately, and `deinit` releases any that
/// escape — a leaked assertion keeps someone's laptop awake all night with nothing to show why.
@Suite("Power assertions")
struct PowerAssertionTests {

    @Test("takes and releases a real assertion")
    func acquiresAndReleases() {
        let assertion = PowerAssertion(reason: "bupsy test")
        #expect(!assertion.isHeld)
        #expect(assertion.acquire())
        #expect(assertion.isHeld)
        assertion.release()
        #expect(!assertion.isHeld)
    }

    /// Callers should not have to track whether they already hold one.
    @Test("acquiring twice and releasing twice are both safe")
    func isIdempotent() {
        let assertion = PowerAssertion(reason: "bupsy test")
        #expect(assertion.acquire())
        #expect(assertion.acquire())
        #expect(assertion.isHeld)
        assertion.release()
        assertion.release()
        #expect(!assertion.isHeld)
    }

    /// The assertion is visible to the system, which is how a user can see who is keeping their
    /// Mac awake — `pmset -g assertions` names us.
    @Test("the assertion is registered with the system under our reason")
    func visibleToSystem() throws {
        let reason = "bupsy-test-\(UUID().uuidString.prefix(8))"
        let assertion = PowerAssertion(reason: reason)
        #expect(assertion.acquire())
        defer { assertion.release() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        #expect(output.contains(reason), "the user must be able to see what is holding them awake")
    }

    @Test("each setting states what it does and does not do")
    func settingsAreHonest() {
        #expect(KeepAwake.never.detail.contains("cut short"))
        // Closing the lid still sleeps, and the UI says so rather than implying otherwise.
        #expect(KeepAwake.whileWorking.detail.contains("Closing the lid"))
        #expect(KeepAwake.allCases.count == 2)
    }
}
