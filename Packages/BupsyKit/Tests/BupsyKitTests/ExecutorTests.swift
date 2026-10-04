import Testing
@testable import BupsyKit

@Suite("Executor")
struct ExecutorTests {
    @Test("Its connector passes no environment — Executor keeps its own keys")
    func connectorCarriesNoSecrets() {
        let server = Executor.server
        #expect(server.name == "executor")
        #expect(server.command == "executor" && server.args == ["mcp"])
        #expect(server.requiredEnvNames.isEmpty)
        let entry = (MCPConfig.document(for: [server])["mcpServers"] as? [String: Any])?["executor"] as? [String: Any]
        #expect(entry?["env"] == nil)
    }

    @Test("Switched on by itself only when installed, missing, and never removed")
    func autoAddRules() {
        #expect(Executor.shouldAutoAdd(installed: true, existing: [], removedByPerson: false))
        #expect(!Executor.shouldAutoAdd(installed: false, existing: [], removedByPerson: false))
        #expect(!Executor.shouldAutoAdd(installed: true, existing: [Executor.server], removedByPerson: false))
        #expect(!Executor.shouldAutoAdd(installed: true, existing: [], removedByPerson: true))
    }

    @Test("Spawned engines get the login PATH first, common places next, each once")
    func searchPathMerges() {
        let path = BinaryResolver.searchPath(current: "/usr/bin:/bin", login: "/Users/x/.nvm/bin:/usr/bin")
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.first == "/Users/x/.nvm/bin")
        #expect(parts.contains("/opt/homebrew/bin"))
        #expect(parts.filter { $0 == "/usr/bin" }.count == 1)
        #expect(parts.contains("/bin"))
    }
}
