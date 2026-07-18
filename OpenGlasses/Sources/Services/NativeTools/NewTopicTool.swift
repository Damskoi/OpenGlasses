import Foundation

extension Notification.Name {
    /// Posted when the user asks for a fresh conversation ("new topic", "start over"). AppState
    /// observes it and clears the LLM history + starts a new persistence thread — the tool stays
    /// decoupled from those services, matching how the registry is wired before AppState finishes
    /// building.
    static let ogNewTopicRequested = Notification.Name("OGNewTopicRequested")
}

/// Hands-free conversation reset. Reachable two ways: the classifier's Tier-0 deterministic route
/// (a bare "new topic" never burns an LLM turn) and normal tool-calling for phrasings the
/// classifier doesn't match ("please forget everything we just talked about").
///
/// The actual clearing is deferred-safe: `LLMService.requestHistoryClear()` clears immediately when
/// idle, but waits for the in-flight turn to finish when the LLM itself invoked this tool —
/// wiping history mid-loop would orphan the pending tool_result and 400 the next request.
@MainActor
final class NewTopicTool: NativeTool {
    let name = "new_topic"
    let description = """
    Start a fresh conversation: clears the assistant's memory of the current chat so the next \
    question starts with a clean slate. Use when the user says "new topic", "start over", "start \
    fresh", "clear the conversation", or "forget this conversation". Takes no parameters. Saved \
    notes, memories, and settings are NOT affected — only the current chat context.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any]
    ]

    func execute(args: [String: Any]) async throws -> String {
        NotificationCenter.default.post(name: .ogNewTopicRequested, object: nil)
        return "Okay — fresh start. What would you like to talk about?"
    }
}
