import Foundation

/// Pure turn loop for the fully on-device live session (docs/plans/BU-offline-live-session.md P1).
///
/// A hands-free voice ↔ vision exchange has a fixed conversational shape:
///
///     idle → listening → transcribing → inferring → speaking → listening → …
///
/// This type is *only* that shape — the phase the session is in and the transitions between
/// phases. It owns no mic, no camera, no model, no clock. The `OfflineLiveSessionService`
/// (P2) feeds it events (speech detected, a finalised transcript, the model's first token, TTS
/// finished) and performs the `Effect`s it returns (begin an inference, cancel one, cancel
/// speech). Keeping the shape pure means every branch — the happy path, barge-in, and a cancel
/// from any state — is table-testable without hardware.
///
/// **Half-duplex, mic-always-open.** The mic opens once on `.start` and closes once on `.stop`;
/// it stays open across turns so the user can barge in while the assistant is speaking. So the
/// only per-turn effects are inference/speech control — `.startListening`/`.stopListening` are
/// session-level and fire exactly once each.
struct LiveSessionTurnLoop {

    /// Conversational phase. `idle` is the only resting state with the mic closed.
    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case inferring
        case speaking
    }

    /// Inputs the service delivers as the world changes.
    enum Event: Equatable {
        /// Begin the session: open the mic.
        case start
        /// Voice-activity onset — the user started talking.
        case speechDetected
        /// A finalised utterance from the STT stack. Empty (silence/noise) returns to listening.
        case transcript(String)
        /// The model produced its first token — the answer is now being spoken.
        case responseBegan
        /// TTS finished speaking the whole answer.
        case speechCompleted
        /// Abandon the current turn but keep the session live (mic stays open).
        case cancel
        /// End the session entirely: close the mic.
        case stop
    }

    /// Side effects for the service to perform. Deliberately narrow — the loop decides *when*,
    /// the service decides *how* (which frame, which model, which voice).
    enum Effect: Equatable {
        case startListening
        case stopListening
        /// Grab a fresh frame (per the freshness policy), assemble the prompt, run the VLM.
        case beginInference(turn: String)
        case cancelInference
        case cancelSpeech
    }

    private(set) var state: State = .idle

    /// Advance the machine and return the effects to perform. Events that don't apply to the
    /// current state are ignored (empty result) so the service never has to pre-check phase.
    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start:
            guard state == .idle else { return [] }
            state = .listening
            return [.startListening]

        case .speechDetected:
            switch state {
            case .listening:
                state = .transcribing
                return []
            case .inferring:
                // The user talks over a pending answer — supersede it.
                state = .transcribing
                return [.cancelInference]
            case .speaking:
                // Barge-in: cut the TTS and capture the new utterance.
                state = .transcribing
                return [.cancelSpeech]
            case .transcribing, .idle:
                return []
            }

        case .transcript(let text):
            guard state == .listening || state == .transcribing else { return [] }
            let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !utterance.isEmpty else {
                // Silence or noise — no turn, keep listening.
                state = .listening
                return []
            }
            state = .inferring
            return [.beginInference(turn: utterance)]

        case .responseBegan:
            guard state == .inferring else { return [] }
            state = .speaking
            return []

        case .speechCompleted:
            guard state == .speaking else { return [] }
            state = .listening
            return []

        case .cancel:
            guard state != .idle else { return [] }
            let effects = activeCancelEffects()
            state = .listening
            return effects

        case .stop:
            guard state != .idle else { return [] }
            let effects = activeCancelEffects() + [.stopListening]
            state = .idle
            return effects
        }
    }

    /// Effect to unwind whatever work is in flight for the state we're leaving.
    private func activeCancelEffects() -> [Effect] {
        switch state {
        case .inferring: return [.cancelInference]
        case .speaking:  return [.cancelSpeech]
        case .idle, .listening, .transcribing: return []
        }
    }
}

/// Ask-time frame freshness (docs/plans/BU-offline-live-session.md P1).
///
/// The offline mode answers on the *newest frame at the moment the question lands* — it never
/// streams frames to the model (a small VLM gets one image per turn). When an inference is about
/// to start, the service asks this policy whether the frame it already has is recent enough or
/// whether to grab a new one. Pure and monotonic-clock based, so the boundary is table-testable.
struct FrameFreshnessPolicy {

    /// Oldest a frame may be, in seconds, and still answer the current question.
    let maxAgeSeconds: TimeInterval

    /// True when the service must capture a new frame before inferring.
    ///
    /// - `frameTimestamp` nil (no frame yet) always refreshes.
    /// - A frame exactly `maxAgeSeconds` old is still fresh (boundary is `>`, not `>=`).
    /// - A future timestamp (clock skew) reads as fresh rather than forcing a needless grab.
    func needsFreshFrame(frameTimestamp: TimeInterval?, now: TimeInterval) -> Bool {
        guard let frameTimestamp else { return true }
        return (now - frameTimestamp) > maxAgeSeconds
    }
}
