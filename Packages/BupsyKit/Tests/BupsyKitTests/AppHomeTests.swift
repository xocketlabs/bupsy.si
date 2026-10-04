import Foundation
import Testing
@testable import BupsyKit

@Suite("App home")
struct AppHomeTests {
    @Test("without BUPSY_HOME, data lives in Application Support/si.bupsy")
    func defaultHome() throws {
        guard ProcessInfo.processInfo.environment["BUPSY_HOME"] == nil else { return }
        #expect(AppHome.directory.path.hasSuffix("Application Support/si.bupsy"))
        #expect(!AppHome.isSandboxed)
        #expect(try Store.defaultURL().lastPathComponent == "bupsy.sqlite")
    }
}
