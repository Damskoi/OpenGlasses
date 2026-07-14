import AppIntents

/// AppIntent for the iPhone Action Button — toggles a Gemini Live session.
/// User configures: Settings → Action Button → Shortcut → "Toggle Gemini Live".
struct ToggleGeminiLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Gemini Live"
    static var description = IntentDescription("Start or stop a Gemini Live session")

    static var isDiscoverable: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentSupport.requireEnabled("gemini_live_toggle")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        if appState.currentMode != .geminiLive {
            appState.switchMode(to: .geminiLive)
            try await Task.sleep(nanoseconds: 600_000_000)
        }

        if appState.geminiLiveSession.isActive {
            appState.geminiLiveSession.stopSession()
        } else {
            await appState.geminiLiveSession.startSession()
        }

        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            "OpenGlasses is not running. Open the app first."
        }
    }
}
