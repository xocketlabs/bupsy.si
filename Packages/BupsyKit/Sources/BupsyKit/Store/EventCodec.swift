import Foundation

/// Turns a canonical event into a durable row and back.
///
/// The stored shape is `(type, payload)` rather than a Swift-encoded enum on purpose: these rows
/// are an audit trail that must stay readable years from now, by `sqlite3` and by a person, after
/// `AgentEvent` has grown cases nobody has thought of yet. An event whose type is no longer
/// recognised decodes to `.unknown` rather than failing the read — the same rule the stream
/// normalisers follow, for the same reason.
public enum EventCodec {
    public static func encode(_ event: AgentEvent) -> (type: String, payload: String) {
        switch event {
        case .started(let id):
            ("started", json(["conversationID": id.rawValue]))
        case .text(let text):
            ("text", json(["text": text]))
        case .thinking(let text):
            ("thinking", json(["text": text]))
        case .toolCall(let call):
            ("toolCall", json([
                "id": call.id, "name": call.name, "arguments": call.argumentsJSON]))
        case .toolResult(let result):
            ("toolResult", json([
                "callID": result.callID, "content": result.content,
                "isError": result.isError ? "true" : "false"]))
        case .approvalRequired(let request):
            ("approvalRequired", json([
                "id": request.id, "tool": request.tool,
                "summary": request.summary, "arguments": request.argumentsJSON]))
        case .usage(let usage):
            ("usage", json([
                "inputTokens": usage.inputTokens.map(String.init) ?? "",
                "outputTokens": usage.outputTokens.map(String.init) ?? ""]))
        case .connectors(let states):
            ("connectors", json(Dictionary(
                uniqueKeysWithValues: states.map { ($0.name, $0.status.rawValue) })))
        case .rateLimit(let limit):
            ("rateLimit", json(limit.windows.mapValues { String($0.utilization) }))
        case .done(let outcome):
            ("done", json([
                "summary": outcome.summary ?? "",
                "conversationID": outcome.conversationID?.rawValue ?? ""]))
        case .failed(let failure):
            ("failed", json(["kind": failure.kind.rawValue, "message": failure.message]))
        case .unknown(let raw):
            ("unknown", raw)
        }
    }

    public static func decode(type: String, payload: String) -> AgentEvent {
        let fields = object(payload)
        switch type {
        case "started":
            guard let id = fields["conversationID"] else { return .unknown(raw: payload) }
            return .started(conversationID: ConversationID(id))
        case "text":
            return .text(fields["text"] ?? "")
        case "thinking":
            return .thinking(fields["text"] ?? "")
        case "toolCall":
            return .toolCall(ToolCall(
                id: fields["id"] ?? "", name: fields["name"] ?? "",
                argumentsJSON: fields["arguments"] ?? "{}"))
        case "toolResult":
            return .toolResult(ToolResult(
                callID: fields["callID"] ?? "", content: fields["content"] ?? "",
                isError: fields["isError"] == "true"))
        case "failed":
            return .failed(EngineFailure(
                kind: EngineFailure.Kind(rawValue: fields["kind"] ?? "") ?? .unknown,
                message: fields["message"] ?? ""))
        case "done":
            let conversation = fields["conversationID"].flatMap {
                $0.isEmpty ? nil : ConversationID($0)
            }
            let summary = fields["summary"].flatMap { $0.isEmpty ? nil : $0 }
            return .done(Outcome(summary: summary, conversationID: conversation))
        default:
            // Includes rows written by a future version of the app. Keep them visible.
            return .unknown(raw: payload)
        }
    }

    private static func json(_ fields: [String: String]) -> String {
        (try? String(data: JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)) ?? "{}"
    }

    private static func object(_ payload: String) -> [String: String] {
        guard let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return parsed
    }
}
