import Foundation
import CryptoKit

/// Shared OAuth building blocks used by both account sign-in flows (Claude and ChatGPT):
/// PKCE derivation (RFC 7636) and pasted-authorization-input parsing. Pure — no I/O.
enum PKCE {

    /// Base64url (no padding) — the encoding PKCE uses for both verifier and challenge.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Derive a code verifier from random bytes (injectable so tests are deterministic).
    static func verifier(from randomBytes: Data) -> String {
        base64URL(randomBytes)
    }

    /// Generate a fresh random verifier (32 random bytes → 43-char base64url string).
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return verifier(from: Data(bytes))
    }

    /// S256 code challenge for a verifier (RFC 7636).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// Parses whatever the user pastes back from a browser sign-in: `code#state`, a bare code, or a
/// full callback URL (including one copied out of the address bar when a localhost redirect
/// couldn't connect). Shared by both sign-in flows.
enum OAuthCodeInput {
    static func parse(_ input: String) -> (code: String, state: String?)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Full callback URL pasted: pull code/state from the query.
        if text.hasPrefix("http"), let components = URLComponents(string: text) {
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value
            if let code, !code.isEmpty { return (code, state) }
            if let fragment = components.fragment { text = fragment } else { return nil }
        }
        let parts = text.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else { return nil }
        return (code, parts.count > 1 ? parts[1] : nil)
    }
}
