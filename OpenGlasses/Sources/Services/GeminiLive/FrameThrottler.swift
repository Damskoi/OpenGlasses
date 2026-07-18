import Foundation
import UIKit

/// Throttles camera frames to a configurable interval before forwarding.
/// Used in Gemini Live mode to rate-limit video frames sent over the WebSocket (default: 1fps).
///
/// When `Config.frameDedupEnabled` is on, a perceptual-hash `FrameGate` runs
/// *after* the time check (Plan AT): time-throttled frames that are visually
/// indistinguishable from the last one sent are dropped before reaching
/// `onThrottledFrame`. With the flag off the gate is never constructed and the
/// behaviour is byte-for-byte the time-only throttle.
class FrameThrottler {
    var onThrottledFrame: ((UIImage) -> Void)?

    /// Fires when a forwarded frame represents a *genuine scene change* (the gate's
    /// first-frame or distinct send, never a heartbeat re-send) — i.e. a keyframe
    /// worth describing. Only ever called when the content gate is active
    /// (`Config.frameDedupEnabled`); with the gate off there is no distinct signal.
    /// Feeds Visual State Memory (Plan AV).
    var onKeyframe: ((UIImage) -> Void)?

    private var lastFrameTime: Date = .distantPast
    private let interval: TimeInterval
    private var isPaused: Bool = false

    /// Power-posture stretch on the interval (Plan BV P2): `1.0` = full rate, higher = fewer frames
    /// under `conserve`/`reserve`. Defaults to `1.0` so the throttle is byte-for-byte unchanged; the
    /// session manager updates it from `PowerPolicyService`'s posture on the main actor (the same
    /// actor `submit` runs on), so no cross-thread read is needed.
    var powerIntervalMultiplier: Double = 1.0

    /// Content gate; non-nil only when `Config.frameDedupEnabled` was set at init.
    private var frameGate: FrameGate?

    /// Injected clock, so the interval/power-multiplier gate is deterministic under test. The live
    /// app leaves the default `Date()`.
    private let now: () -> Date

    /// - Parameter interval: Minimum seconds between forwarded frames (default: from Config).
    init(interval: TimeInterval = Config.geminiLiveVideoFrameInterval, now: @escaping () -> Date = { Date() }) {
        self.interval = interval
        self.now = now
        if Config.frameDedupEnabled {
            frameGate = FrameGate(
                hammingThreshold: Config.frameDedupHammingThreshold,
                heartbeat: Config.frameDedupHeartbeatSeconds
            )
        }
    }

    /// Total frames received and forwarded (for diagnostics).
    private(set) var receivedCount: Int = 0
    private(set) var forwardedCount: Int = 0

    /// Fraction of time-throttled frames dropped by the content gate (0 when disabled).
    var dedupRatio: Double { frameGate?.dedupRatio ?? 0 }

    /// Temporarily pause frame forwarding (e.g. during tool execution).
    func pause() {
        isPaused = true
    }

    /// Resume frame forwarding after a pause.
    func resume() {
        isPaused = false
    }

    /// Call with every camera frame. Only forwards if enough time has passed,
    /// not paused, and the content gate (if enabled) considers it distinct.
    func submit(_ image: UIImage) {
        receivedCount += 1
        guard !isPaused else { return }
        let now = self.now()
        let effectiveInterval = interval * max(1.0, powerIntervalMultiplier)
        guard now.timeIntervalSince(lastFrameTime) >= effectiveInterval else { return }

        // Content gate runs after the time gate. dhash failure → fail open (send).
        var isKeyframe = false
        if frameGate != nil, let hash = PerceptualHash.dhash(image) {
            let decision = frameGate!.evaluate(hash: hash, now: now.timeIntervalSinceReferenceDate)
            guard decision == .send else { return }
            isKeyframe = frameGate!.lastSendReason != .heartbeat
        }

        lastFrameTime = now
        forwardedCount += 1
        if forwardedCount <= 3 || forwardedCount % 10 == 0 {
            NSLog("[FrameThrottler] Forwarding frame #%d (received %d total, dedupRatio %.2f)",
                  forwardedCount, receivedCount, dedupRatio)
        }
        onThrottledFrame?(image)
        if isKeyframe { onKeyframe?(image) }
    }

    /// Reset the throttle timer (e.g. on session restart).
    func reset() {
        lastFrameTime = .distantPast
        receivedCount = 0
        forwardedCount = 0
        frameGate?.reset()
    }
}
