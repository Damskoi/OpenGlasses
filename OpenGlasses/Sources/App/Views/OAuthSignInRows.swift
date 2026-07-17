import SwiftUI

/// What a browser-based account sign-in service looks like to the UI (Plan BW P3). Both the
/// Claude and ChatGPT OAuth services conform, so the model editor renders one component for
/// either instead of hand-rolled per-provider copies.
@MainActor
protocol OAuthSignInService: ObservableObject {
    var isConnected: Bool { get }
    var lastError: String? { get }
    func beginSignIn() -> URL?
    @discardableResult
    func completeSignIn(pastedCode: String) async -> Bool
    func signOut()
}

extension ClaudeOAuthService: OAuthSignInService {}
extension ChatGPTOAuthService: OAuthSignInService {}

/// Dark full-screen-styled account sign-in section for the onboarding flow: same behaviour as
/// `OAuthSignInRows`, restyled for the black onboarding pages. Generalized from the original
/// Claude-only onboarding section so ChatGPT reuses it (BW P4).
struct DarkAccountSignInSection<Service: OAuthSignInService>: View {
    @ObservedObject var service: Service
    let signInLabel: String
    let caption: String
    let connectedCaption: String
    let pasteInstructions: String
    /// Show the "or paste an API key" divider under the sign-in button (providers that also
    /// accept a key; ChatGPT has no key so it hides it).
    var showKeyDivider: Bool = false
    var onConnected: () -> Void = {}
    var onSignedOut: () -> Void = {}

    @State private var showCodeField = false
    @State private var code = ""
    @State private var isExchanging = false

    var body: some View {
        if service.isConnected {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Account connected")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Text(connectedCaption)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button("Sign out") {
                    service.signOut()
                    onSignedOut()
                }
                .font(.caption)
                .foregroundStyle(.red.opacity(0.8))
            }
            .padding(14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.green.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, 28)
        } else {
            VStack(spacing: 10) {
                Button {
                    if let url = service.beginSignIn() {
                        UIApplication.shared.open(url)
                        showCodeField = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text(signInLabel)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                if showCodeField {
                    TextField("Paste authorization code", text: $code)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        Task {
                            isExchanging = true
                            let ok = await service.completeSignIn(pastedCode: code)
                            isExchanging = false
                            if ok {
                                code = ""
                                showCodeField = false
                                onConnected()
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isExchanging {
                                ProgressView().scaleEffect(0.8)
                                Text("Connecting…")
                            } else {
                                Image(systemName: "link")
                                Text("Connect")
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isExchanging)

                    Text(pasteInstructions)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }

                if let error = service.lastError {
                    Label(error, systemImage: "xmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.8))
                }

                if showKeyDivider {
                    HStack(spacing: 12) {
                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                        Text("or paste an API key")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize()
                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 28)
        }
    }
}

/// Form-styled account sign-in rows: connected card with sign-out, or a sign-in button that
/// opens the browser and reveals a paste-the-code field. Generalized from the original
/// Claude-only rows in the model editor.
struct OAuthSignInRows<Service: OAuthSignInService>: View {
    @ObservedObject var service: Service
    let signInLabel: String
    let connectedLabel: String
    let connectedCaption: String
    let pasteInstructions: String
    /// Called when the connection state changes (sign-in completed / signed out), so the host
    /// can invalidate anything derived from the credential (e.g. a fetched model list).
    var onChange: () -> Void = {}

    @State private var showCodeField = false
    @State private var code = ""
    @State private var isExchanging = false

    var body: some View {
        if service.isConnected {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectedLabel)
                    Text(connectedCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign out", role: .destructive) {
                    service.signOut()
                    onChange()
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button {
                if let url = service.beginSignIn() {
                    UIApplication.shared.open(url)
                    showCodeField = true
                }
            } label: {
                Label(signInLabel, systemImage: "person.crop.circle.badge.checkmark")
            }

            if showCodeField {
                TextField("Paste authorization code", text: $code)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.footnote.monospaced())

                Button {
                    Task {
                        isExchanging = true
                        let ok = await service.completeSignIn(pastedCode: code)
                        isExchanging = false
                        if ok {
                            code = ""
                            showCodeField = false
                            onChange()
                        }
                    }
                } label: {
                    HStack {
                        if isExchanging {
                            ProgressView().scaleEffect(0.8)
                            Text("Connecting…")
                        } else {
                            Image(systemName: "link")
                            Text("Connect")
                        }
                    }
                }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isExchanging)

                Text(pasteInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = service.lastError {
                Label(error, systemImage: "xmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
