import Foundation

/// Detects "a new page is now settled in front of the reader" from camera frame hashes
/// (docs/plans/BT-reading-companion.md P1).
///
/// A page turn is *a large visual change followed by stillness*. The change half is already
/// solved by `FrameGate`, so this reads that one signal two ways:
///
/// - a **send** (`.firstFrame` / `.distinct`) means the view genuinely changed → a new page
///   *candidate*, and the stability clock restarts;
/// - a **drop** means the view still looks like the candidate → stillness is accumulating.
///
/// Once a candidate has held still for `stabilityWindow`, the frame in hand is a settled page and
/// `.pageSettled` fires exactly once for it. Motion blur, the turning page itself, and a hand
/// across the book never hold still that long — each transient restarts the clock — so they are
/// rejected here and never reach OCR. That rejection is the whole point: OCR is the expensive
/// stage, and a blurred page yields garbage text that would poison the grounding corpus.
///
/// The detector deliberately uses one threshold for both halves: whatever `FrameGate` calls
/// "a different scene" is a page change, and whatever it calls "the same scene" is stillness.
/// Two bars would let a frame be neither.
///
/// Pure value type with time injected via `now` — no `Date()` inside, so every branch is
/// deterministic and headless-testable.
struct PageTurnDetector {

    enum Event: Equatable {
        /// Nothing to do: still moving, or this page has already been reported.
        case none
        /// The frame just evaluated is a settled new page — OCR *that* frame. `hash` is the
        /// evaluated frame's own hash rather than the candidate's, because that frame is the one
        /// the text gets read from, which makes it the right key for `ReadingSessionStore` dedup.
        case pageSettled(hash: UInt64)
    }

    /// Gate tuned for pages rather than for the LLM's visual context: no heartbeat (a page that
    /// simply stays put is not news) and no adaptive threshold (it widens the drop window in
    /// static scenes, and a book on a table is the most static scene there is — it would swallow
    /// the very page turns we're here to catch).
    static func defaultGate() -> FrameGate {
        FrameGate(hammingThreshold: 3, heartbeat: 0, adaptiveEnabled: false)
    }

    private var gate: FrameGate
    private let stabilityWindow: TimeInterval

    private var candidateSince: TimeInterval?
    private var candidateSettled = false

    private(set) var settledCount = 0
    /// Candidates abandoned before they held still — blur, hands, pages mid-turn. Rises with a
    /// shaky reader or a bad `stabilityWindow`, so it's the number to watch on the P3 device pass.
    private(set) var rejectedCandidateCount = 0

    /// - Parameters:
    ///   - gate: change/stillness detector (default: `defaultGate()`).
    ///   - stabilityWindow: seconds a candidate must hold still to count as settled (default 1).
    init(gate: FrameGate = PageTurnDetector.defaultGate(), stabilityWindow: TimeInterval = 1.0) {
        self.gate = gate
        self.stabilityWindow = max(0, stabilityWindow)
    }

    /// True while a candidate is waiting out the stability window.
    var isSettling: Bool { candidateSince != nil && !candidateSettled }

    /// Feed one frame's hash. Returns `.pageSettled` on the frame that confirms a new page.
    ///
    /// Note this needs at least one frame *after* the change to confirm stillness: the caller must
    /// keep frames coming while a session is live, not stop at the change itself.
    mutating func evaluate(hash: UInt64, now: TimeInterval) -> Event {
        switch gate.evaluate(hash: hash, now: now) {
        case .send:
            // A heartbeat re-send is the same scene forced through on a timer, not a change.
            // Ignoring it stops a page the reader is lingering on from re-settling forever.
            if gate.lastSendReason == .heartbeat { return .none }
            if isSettling { rejectedCandidateCount += 1 }
            candidateSince = now
            candidateSettled = false
            return .none

        case .drop:
            guard let since = candidateSince, !candidateSettled,
                  now - since >= stabilityWindow else { return .none }
            candidateSettled = true
            settledCount += 1
            return .pageSettled(hash: hash)
        }
    }

    /// Clear all state (e.g. on session start/resume).
    mutating func reset() {
        gate.reset()
        candidateSince = nil
        candidateSettled = false
        settledCount = 0
        rejectedCandidateCount = 0
    }
}
