import Foundation

/// What a tool call means to a person, rather than what the engine calls it.
///
/// "Bash needs approval" is an engine's vocabulary. The person deciding is being asked whether a
/// bot may *run a command*, and the wording of that question is part of the decision: a name they
/// have to translate is a name they skim past, which is the failure an approval prompt exists to
/// prevent.
public enum ToolNames {

    /// A short phrase completing "wants to …", e.g. "run a command".
    public static func action(_ tool: String) -> String {
        if let server = mcpServer(tool) { return "use \(server)" }
        switch tool {
        case "Bash", "shell", "PowerShell": return "run a command"
        case "Edit", "MultiEdit", "edit": return "edit a file"
        case "Write": return "write a file"
        case "Read", "NotebookRead": return "read a file"
        case "Glob", "Grep": return "search files"
        case "WebFetch": return "fetch a web page"
        case "WebSearch": return "search the web"
        case "NotebookEdit": return "edit a notebook"
        case "Task": return "start a sub-agent"
        default: return "use \(tool)"
        }
    }

    /// Whether the payload is a command line, and so must be shown in a fixed-width font.
    ///
    /// In a proportional font `ls` renders as "Is" — a capital I — which is the one place in the
    /// app where a command most needs to be unambiguous. Measured in the attention inbox.
    /// Whether "always allow" is offered for a tool.
    ///
    /// Not for shell commands: their risk is in the command, not the tool's name, and "always
    /// allow Bash" would allow `rm -rf ~` as readily as `ls`. Those are asked each time.
    public static func canAlwaysAllow(_ tool: String) -> Bool {
        !isCommand(tool) && tool != "Bash"
    }

    public static func isCommand(_ tool: String) -> Bool {
        ["Bash", "shell", "PowerShell"].contains(tool)
    }

    /// `mcp__linear__create_issue` → "Linear". The server is what the person installed and will
    /// recognise; the individual function name is detail.
    static func mcpServer(_ tool: String) -> String? {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty else { return nil }
        return parts[1].prefix(1).uppercased() + parts[1].dropFirst()
    }
}
