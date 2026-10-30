import AuthenticationServices
import ParleyKit
import SwiftUI

/// The first screen until the person is signed in: the app's name and icon,
/// the relay's address (the build's default, editable) and Sign in, which
/// opens Pocket ID and then checks that the relay answers. Problems are shown
/// under the address.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var urlText = ""
    @State private var errorText: String?
    @State private var working = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                header
                    .padding(.top, 72)
                form
                footer
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .onAppear {
            if urlText.isEmpty { urlText = model.relayURLString }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .accessibilityHidden(true)
            Text("Parley")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("loginTitle")
            Text("Talk with your agent, and hear it answer in your own voice.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Relay")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("https://parley.example.ts.net", text: $urlText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($urlFocused)
                .onSubmit { start() }
                .onChange(of: urlText) { _, _ in if !working { errorText = nil } }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(working)
                .accessibilityLabel("Relay address")
                .accessibilityIdentifier("loginRelayURL")
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(SuiTone.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("loginError")
            }
            Button(action: start) {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(.white) }
                    Text(buttonTitle).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working || model.oidcConfiguration == nil
                      || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.top, 6)
            .accessibilityIdentifier("loginButton")
            if model.isSignedIn && !working {
                HStack {
                    Text("Signed in as \(model.account?.label ?? "you")")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("loginAccount")
                    Spacer()
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                        .accessibilityIdentifier("loginSignOut")
                }
                .font(.footnote)
            }
        }
    }

    private var footer: some View {
        Text(footerText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var buttonTitle: String {
        if working { return model.isSignedIn ? "Connecting…" : "Signing in…" }
        return model.isSignedIn ? "Try again" : "Sign in"
    }

    private var footerText: String {
        guard let issuer = model.oidcConfiguration?.issuer.host else {
            return "This build has no sign-in configured."
        }
        return "You sign in with Pocket ID (\(issuer)). You stay signed in on this phone; the session is kept in its Keychain and sent only to your relay."
    }

    private func start() {
        guard !working else { return }
        urlFocused = false
        if case .failure(let problem) = model.validate(relayURL: urlText) {
            errorText = problem.localizedDescription
            return
        }
        working = true
        errorText = nil
        Task {
            defer { working = false }
            do {
                try await model.logIn(relayURL: urlText, using: webAuthenticationSession)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Closed by the person: nothing to say.
            } catch let error as LoginError {
                errorText = error.localizedDescription
            } catch {
                errorText = "The sign-in did not complete. \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
        }
    }
}
