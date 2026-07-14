import Foundation
import MWDATCore

/// Plan BR P2 — tiered camera-stream recovery + DAT compatibility messaging (pure).
///
/// Stall recovery previously tore down the whole `DeviceSession` every time. The session
/// is the expensive, slow-to-restart half (BT connection + permission state); the `Stream`
/// is cheap. Policy: rebuild the stream on the retained session first, and only escalate
/// to a full session reset when stream-level rebuilds keep failing. (DAT 0.8 has no
/// `removeStream` — a stream rebuild is stop + `addStream(config:)` on the live session;
/// if that throws, the caller escalates.)
enum StreamRecoveryPolicy {
    enum Action: Equatable {
        /// Stop + re-add the Stream; keep the DeviceSession.
        case rebuildStream
        /// Tear down and recreate the DeviceSession too.
        case resetSession
    }

    /// Consecutive failed recoveries (0 on the first attempt after healthy streaming).
    static func action(consecutiveFailures: Int) -> Action {
        consecutiveFailures < 2 ? .rebuildStream : .resetSession
    }
}

/// Maps DAT compatibility signals to actionable user copy — an outdated Meta AI app or
/// glasses firmware otherwise presents as a mystery connection failure.
enum DATCompatibilityMessage {
    static func message(for error: DeviceSessionError) -> String? {
        switch error {
        case .datAppOnTheGlassesUpdateRequired:
            return "Your glasses need an update before streaming can work — open the Meta AI app and install the pending update."
        default:
            return nil
        }
    }

    static func message(for compatibility: Compatibility) -> String? {
        switch compatibility {
        case .deviceUpdateRequired:
            return "Your glasses need a firmware update — open the Meta AI app to update them."
        case .sdkUpdateRequired:
            return "This version of OpenGlasses is too old for your glasses — update OpenGlasses from the App Store."
        case .compatible, .undefined:
            return nil
        @unknown default:
            return nil
        }
    }
}
