import Foundation

/// Executor (executor.sh, MIT): one connection to every tool the person has set up in it.
///
/// A local gateway. Tools are connected once in Executor's own app — MCP servers, REST and GraphQL
/// APIs — and any agent reaches all of them through a single MCP server. That makes it the natural
/// default for bupsy, and it fits the credential rule exactly: Executor keeps the logins and
/// attaches them when a tool is called, so bupsy passes it no environment at all, not even names.
///
/// Detected and installed the way engines are — found where the person put it, or set up by its
/// own installer in a Terminal they can watch. Never bundled: shipping someone else's credential
/// store inside bupsy would make it ours to vouch for and to keep patched.
public enum Executor {
    /// The connector's name, and so the prefix of every tool it offers: `mcp__executor__…`.
    public static let name = "executor"

    /// Its stdio MCP entry point, as Executor's README documents it.
    public static var server: MCPServer {
        MCPServer(id: "executor", name: name, command: "executor", args: ["mcp"])
    }

    /// Executor's own install steps from its README: the npm package, then its background service.
    /// Run in Terminal, in view, so the person sees exactly what is installed.
    public static let installScript = """
        if ! command -v npm >/dev/null 2>&1; then
          echo "Executor needs Node.js. Install it from https://nodejs.org, then click Install in Bupsy again."
          exit 1
        fi
        npm install -g executor && executor install && echo && echo "Done. You can close this window. Back in Bupsy, Executor is on for every bot."
        """

    /// Where Executor's web app runs once its service is installed, to connect tools in.
    public static let webURL = URL(string: "http://127.0.0.1:4788")!

    /// Whether `executor` is on this Mac, found the way a login shell would find it.
    public static func isInstalled() -> Bool {
        (try? BinaryResolver.resolve("executor")) != nil
    }

    /// Whether bupsy should switch Executor on by itself.
    ///
    /// Only when it is installed, not already set up, and the person has not removed it before —
    /// a default that comes back after being turned off is not a default, it is nagging.
    public static func shouldAutoAdd(installed: Bool, existing: [MCPServer], removedByPerson: Bool) -> Bool {
        installed && !removedByPerson && !existing.contains { $0.name == name }
    }
}
