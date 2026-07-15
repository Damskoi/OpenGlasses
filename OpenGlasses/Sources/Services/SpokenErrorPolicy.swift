import Foundation

/// What an error is allowed to sound like (pure).
///
/// Live-traced failure: a model-load `DecodingError` reached TTS verbatim and the glasses
/// read out "keyNotFound(path: [language_model, model, layers, 15…" to the user. Spoken
/// errors must be human sentences; internals belong in the log.
enum SpokenErrorPolicy {
    /// A short, speakable reason. Uses the error's `localizedDescription` only when it
    /// looks like prose; otherwise a generic line.
    static func spokenReason(for error: Error) -> String {
        let description = error.localizedDescription
        return looksHuman(description) ? description : "Something went wrong on the device — check the debug log for details."
    }

    /// Prose heuristic: short, no code-ish brackets/underscores/paths, has spaces.
    static func looksHuman(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 200, text.contains(" ") else { return false }
        let codey: [Character] = ["[", "]", "{", "}", "_", "(", ")"]
        let codeyCount = text.filter { codey.contains($0) }.count
        return codeyCount < 3 && !text.contains("keyNotFound") && !text.contains("Error Domain")
    }
}
