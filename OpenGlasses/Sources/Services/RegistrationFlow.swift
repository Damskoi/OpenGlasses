import Foundation

/// Pure policy for the Meta registration wait — the setup step that most often blocks users
/// (the DAT permission gate is *the* onboarding blocker).
///
/// `Wearables.startRegistration()` returns *before* the user has approved the app inside the Meta
/// AI companion app; `registrationState` only reaches the camera/mic-capable value once they do,
/// and that approval has been observed to take ~25 s. The old 10 s deadline gave up while the user
/// was still tapping through Meta AI, leaving a "connected but nothing works" state — and the
/// status shown was a raw internal state number, not something the user could act on.
enum RegistrationFlow {
    /// How long to keep polling for the Meta AI approval before giving up (still with guidance).
    static let approvalDeadlineSeconds: Int64 = 25
    /// `registrationState` raw value at which camera/mic capabilities become available.
    static let registeredStateRawValue = 3

    static func isRegistered(stateRaw: Int) -> Bool { stateRaw >= registeredStateRawValue }

    /// User-facing connection status — tells the user what to *do*, never an internal state number.
    static func status(stateRaw: Int) -> String {
        isRegistered(stateRaw: stateRaw)
            ? "Waiting for device…"
            : "Approve OpenGlasses in the Meta AI app to continue…"
    }

    /// Diagnostic failure message for a connect that gave up — names the stalled layer instead of
    /// a bare "Could not connect to glasses" (issue #246: that string hid a broken registration
    /// link-back for an entire debugging evening). Still actionable, now also diagnosable.
    static func connectFailureMessage(stateRaw: Int) -> String {
        if isRegistered(stateRaw: stateRaw) {
            return "Glasses registered but no device appeared (state \(stateRaw)). Make sure the glasses are on, nearby, and connected in the Meta AI app, then try again."
        }
        return "Glasses registration didn't complete (state \(stateRaw)). If you approved OpenGlasses in the Meta AI app and this persists, the approval link-back may not be reaching this app — on a custom build, verify the AppLink domain and associated-domains entitlement match your bundle ID."
    }
}
