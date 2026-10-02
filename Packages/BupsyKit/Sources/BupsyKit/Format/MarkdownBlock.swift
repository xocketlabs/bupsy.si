import Foundation

/// Splits a reply into prose and code.
///
/// SwiftUI's markdown is inline-only, so a fenced code block arrives as run-together prose with
/// its newlines collapsed. For agents whose whole job is writing code, that is the single worst
/// rendering bug in the app — a diff or a shell command becomes unreadable at exactly the moment
/// you need to read it carefully.
public enum MarkdownBlock: Identifiable, Equatable {
    case prose(String)
    case code(language: String?, text: String)

    public var id: String {
        switch self {
        case .prose(let text): "p\(text.hashValue)"
        case .code(let language, let text): "c\(language ?? "")\(text.hashValue)"
        }
    }

    /// Parses triple-backtick fences. Deliberately only fences: that is what engines emit, and a
    /// fuller markdown parser would be a lot of surface for very little more fidelity.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.prose(text)) }
            prose.removeAll()
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(
                        language: language,
                        text: code.joined(separator: "\n")))
                    code.removeAll()
                    language = nil
                    inCode = false
                } else {
                    flushProse()
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : String(tag)
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }

        // An unclosed fence is normal mid-stream: the block is still arriving. Show it as code
        // rather than holding it back, so a long answer renders as it lands.
        if inCode, !code.isEmpty {
            blocks.append(.code(language: language, text: code.joined(separator: "\n")))
        }
        flushProse()
        return blocks
    }
}

