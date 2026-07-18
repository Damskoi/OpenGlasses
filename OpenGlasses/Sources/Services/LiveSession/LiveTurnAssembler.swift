import Foundation

/// Builds the per-turn prompt for the offline live session (docs/plans/BU-offline-live-session.md P1).
///
/// The payload is deliberately small — a 500M–2B on-device VLM has a tight context and one image
/// per turn. The assembler produces a compact system prompt (optional persona + a fixed grounding
/// rule) and a budget-capped rolling window of recent turns. The *current* utterance is passed to
/// the model separately as the user message; `assemble` only prepares the standing context.
///
/// **The grounding rule is the safety contract and is never truncated** — same posture as the
/// `ReadingContextBuilder` spoiler rule. It tells the model it's answering out loud about what the
/// wearer sees *now*, to speak plainly, and to admit when the thing asked about isn't in frame
/// rather than hallucinating from world knowledge. Persona text gets whatever budget is left.
///
/// Pure and headless — no store, no `Date()`, no I/O.
enum LiveTurnAssembler {

    static let groundingRule = """
        You are a hands-free voice assistant answering out loud about what the wearer is looking \
        at right now. Answer only from the current camera image and the recent conversation. If \
        the thing being asked about is not visible in the image, say you cannot see it instead of \
        guessing. Keep replies short and speakable — a sentence or two, no lists, no markdown.
        """

    enum Role: String, Equatable { case user, assistant }

    /// One prior exchange in the rolling transcript window.
    struct Turn: Equatable {
        let role: Role
        let text: String

        init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    struct HistoryTurn: Equatable {
        let role: String
        let content: String
    }

    struct Assembled: Equatable {
        let systemPrompt: String
        /// Prior turns, oldest→newest, capped to the history budget. The current utterance is NOT
        /// here — the caller passes it as the VLM user message.
        let history: [HistoryTurn]
    }

    /// Assemble the standing context for a turn.
    ///
    /// - Parameters:
    ///   - persona: optional compact persona/preamble; clipped to fit, never allowed to crowd out
    ///     the grounding rule.
    ///   - priorTurns: the conversation so far in chronological order (excluding the current
    ///     utterance). The most recent turns that fit `historyBudgetCharacters` are kept; older
    ///     ones drop — the wearer's question is nearly always about the here and now.
    ///   - systemBudgetCharacters: ceiling on the system prompt (default 800 ≈ 200 tokens).
    ///   - historyBudgetCharacters: ceiling on the rolling window (default 1200 ≈ 300 tokens).
    static func assemble(persona: String?,
                         priorTurns: [Turn],
                         systemBudgetCharacters: Int = 800,
                         historyBudgetCharacters: Int = 1200) -> Assembled {
        Assembled(
            systemPrompt: systemPrompt(persona: persona, budgetCharacters: systemBudgetCharacters),
            history: rollingWindow(priorTurns, budgetCharacters: historyBudgetCharacters)
        )
    }

    /// Compact persona (if any) followed by the immutable grounding rule.
    static func systemPrompt(persona: String?, budgetCharacters: Int = 800) -> String {
        guard let trimmed = persona?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return groundingRule
        }
        // The grounding rule ships whole; persona takes whatever remains after it and the separator.
        let personaRoom = budgetCharacters - groundingRule.count - 2
        guard personaRoom > 0 else { return groundingRule }
        let clipped = trimmed.count > personaRoom ? String(trimmed.prefix(personaRoom)) : trimmed
        guard !clipped.isEmpty else { return groundingRule }
        return clipped + "\n\n" + groundingRule
    }

    /// Keep the most recent turns that fit the budget, dropping the oldest and any empty turns.
    /// Returned oldest→newest so it reads as a transcript.
    static func rollingWindow(_ turns: [Turn], budgetCharacters: Int) -> [HistoryTurn] {
        var kept: [HistoryTurn] = []
        var used = 0
        for turn in turns.reversed() {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let cost = text.count + 1
            guard used + cost <= budgetCharacters else { break }
            kept.insert(HistoryTurn(role: turn.role.rawValue, content: text), at: 0)
            used += cost
        }
        return kept
    }
}
