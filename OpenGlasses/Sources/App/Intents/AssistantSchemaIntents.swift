import AppIntents

// MARK: - Plan BQ P3 — assistant App Schema adoption
//
// The `assistant` domain has exactly one schema intent — `activate` — Apple's shape for
// "activate this app's voice assistant" (the same surface third-party assistants bind to
// the Action Button and Siri's pre-trained activation phrasing). It's precisely what
// `AskOpenGlassesIntent` already does as a plain intent; this schema twin makes that
// capability visible to the system as *an assistant*, not just an app action.
// `AskOpenGlassesIntent` stays — users' existing shortcuts and the App Shortcut phrase
// reference it.

/// "Activate OpenGlasses" → start listening for a voice command immediately (no wake word).
/// (The assistant domain shipped in iOS 26.2 — the intent simply doesn't exist on 26.0/26.1
/// devices; `AskOpenGlassesIntent` covers them.)
@available(iOS 26.2, *)
@AppIntent(schema: .assistant.activate)
struct ActivateGlassesAssistantIntent {
    // Schema contract (metadata-processor enforced): assistant activation is a
    // foreground-only intent — `supportedModes`, not the legacy `openAppWhenRun`.
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await IntentSupport.awaitConnectedAppState()

        if appState.currentMode != .direct {
            appState.switchMode(to: .direct)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        appState.wakeWordService.stopListening()
        appState.startDirectTranscription()

        return .result()
    }
}
