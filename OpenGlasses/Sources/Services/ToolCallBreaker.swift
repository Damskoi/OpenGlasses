import CryptoKit
import Foundation

/// Plan BR P1 — circuit breaker for live-session tool calling.
///
/// A realtime model can loop tool calls — retrying the same failing tool, or ping-ponging
/// between tools — with no user turn to break the cycle, burning battery and quota
/// mid-session. This pure type tracks two windows per session and suspends tools that trip
/// either. The router consults it before dispatch; the session manager resets the
/// consecutive window on each user turn and filters suspended tools out of re-declared
/// tool lists on reconnect. The notice to the user is delivered *in-band*: the synthetic
/// tool result instructs the model to say the tool is unavailable — no side-channel TTS
/// fighting the live audio.
///
/// One instance per live session (owned by `ToolCallRouter`, which is recreated each
/// session) — suspensions never outlive the session.
struct ToolCallBreaker {
    struct Config {
        /// Tool calls allowed with no intervening user turn before the breaker trips.
        var maxConsecutiveCalls: Int = 12
        /// Identical (tool + args) failures before that tool is suspended.
        var maxIdenticalFailures: Int = 3
    }

    enum Verdict: Equatable {
        case allowed
        /// The call must not run; respond with `message` as the tool error.
        case suspended(message: String)
    }

    private let config: Config
    private(set) var suspendedTools: Set<String> = []
    private var consecutiveCalls = 0
    private var failureStreaks: [String: Int] = [:]

    init(config: Config = Config()) {
        self.config = config
    }

    /// A user turn (speech reaching the model) breaks any runaway window.
    mutating func recordUserTurn() {
        consecutiveCalls = 0
    }

    /// Consult before dispatching. Also counts the call against the consecutive window —
    /// call exactly once per tool call.
    mutating func admit(toolName: String) -> Verdict {
        if suspendedTools.contains(toolName) {
            return .suspended(message: Self.suspensionNotice(toolName))
        }
        consecutiveCalls += 1
        if consecutiveCalls > config.maxConsecutiveCalls {
            suspend(toolName)
            return .suspended(message: Self.runawayNotice(toolName))
        }
        return .allowed
    }

    /// Record the outcome of a dispatched call. Returns a suspension message if this
    /// failure tripped the identical-failure breaker (the caller appends it to the error
    /// result so the model learns in-band).
    mutating func recordOutcome(toolName: String, argsKey: String, success: Bool) -> String? {
        let streakKey = "\(toolName)|\(argsKey)"
        if success {
            failureStreaks[streakKey] = nil
            return nil
        }
        let streak = (failureStreaks[streakKey] ?? 0) + 1
        failureStreaks[streakKey] = streak
        guard streak >= config.maxIdenticalFailures else { return nil }
        suspend(toolName)
        return Self.repeatedFailureNotice(toolName)
    }

    /// Stable fingerprint for "identical call" detection, insensitive to dictionary
    /// ordering.
    static func argsKey(_ args: [String: Any]) -> String {
        let canonical = args.keys.sorted()
            .map { "\($0)=\(String(describing: args[$0] ?? ""))" }
            .joined(separator: "&")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func suspend(_ toolName: String) {
        suspendedTools.insert(toolName)
    }

    // MARK: In-band notices (spoken by the model, so keep them instructional)

    static func suspensionNotice(_ tool: String) -> String {
        "The '\(tool)' tool is disabled for the rest of this session. Do not call it again; tell the user it's unavailable right now."
    }

    static func runawayNotice(_ tool: String) -> String {
        "Too many consecutive tool calls without user input — '\(tool)' is now disabled for this session. Stop calling tools, summarize what you have, and wait for the user."
    }

    static func repeatedFailureNotice(_ tool: String) -> String {
        "The '\(tool)' tool failed repeatedly with the same input and is disabled for this session. Do not retry it; tell the user briefly and continue without it."
    }
}
