import AuthenticationServices
import ParleyKit
import SwiftData
import SwiftUI
import UserNotifications

/// The relay URL, signing in with Pocket ID (or a dev relay's token), and
/// notification permission.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PlayerController.self) private var player
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var checkResult: String?
    @State private var signInError: String?
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://relay.example.ts.net", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("relayURLField")
                    Button("Check connection") { Task { await check() } }
                        .disabled(RelayConfiguration.parseURL(urlText) == nil || !canAuthenticate)
                        .accessibilityIdentifier("checkConnection")
                    if let url = RelayConfiguration.parseURL(urlText),
                       let problem = model.problem(baseURL: url, devToken: trimmedToken), model.isSignedIn {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("relayProblem")
                    }
                    if let checkResult {
                        Text(checkResult).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("checkResult")
                    }
                } header: {
                    Text("Relay")
                } footer: {
                    Text("The relay's address on your tailnet.")
                }
                accountSection
                Section {
                    SecureField("Dev token", text: $tokenText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("tokenField")
                } header: {
                    Text("Dev relay")
                } footer: {
                    Text("Only for a dev relay (parley-relay --dev): its token, used instead of the sign-in. Leave it empty for your real relay. It stays in this phone's Keychain.")
                }
                Section {
                    LabeledContent("Status", value: notificationLabel)
                        .accessibilityIdentifier("notificationStatus")
                    if model.notifier.authorization == .notDetermined {
                        Button("Allow notifications") { Task { await model.notifier.requestAuthorization() } }
                            .accessibilityIdentifier("allowNotifications")
                    }
                    LabeledContent("Push", value: pushLabel)
                        .accessibilityIdentifier("pushStatus")
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(notificationFooter)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                        .accessibilityIdentifier("settingsDone")
                }
            }
            .onAppear {
                urlText = model.relayURLString
                tokenText = model.devToken
            }
            .task { await model.notifier.refreshAuthorization() }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if model.isSignedIn {
                LabeledContent("Signed in as", value: model.account?.label ?? "you")
                    .accessibilityIdentifier("accountLabel")
                Button("Sign out", role: .destructive) { Task { await signOut() } }
                    .accessibilityIdentifier("signOutButton")
            } else {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign in")
                        if signingIn {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(signingIn || model.oidcConfiguration == nil)
                .accessibilityIdentifier("signInButton")
            }
            if let signInError {
                Text(signInError).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("signInError")
            }
        } header: {
            Text("Account")
        } footer: {
            Text(accountFooter)
        }
    }

    private var accountFooter: String {
        guard let issuer = model.oidcConfiguration?.issuer.host else {
            return "This build has no sign-in configured."
        }
        var text = "Sign in with Pocket ID (\(issuer)) to reach your relay through its door. You stay signed in on this phone; the session is kept in its Keychain."
        if !tokenText.trimmingCharacters(in: .whitespaces).isEmpty {
            text += " A dev token is set, so it is used instead."
        }
        return text
    }

    private var trimmedToken: String { tokenText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAuthenticate: Bool {
        guard let url = RelayConfiguration.parseURL(urlText) else { return false }
        return model.client(baseURL: url, devToken: trimmedToken) != nil
    }

    private var notificationLabel: String {
        switch model.notifier.authorization {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Off (change it in Settings)"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private func save() {
        model.update(relayURL: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                     devToken: tokenText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sign out, and forget what this phone kept of the relay: the cached
    /// conversations and the reply audio.
    private func signOut() async {
        player.stop()
        await model.signOut()
        CacheStore.removeAll(in: context)
        AudioCache.removeAll()
        checkResult = nil
    }

    private func signIn() async {
        signingIn = true
        signInError = nil
        defer { signingIn = false }
        do {
            try await model.signIn(using: webAuthenticationSession)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed by the person: nothing to say.
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func check() async {
        guard let url = RelayConfiguration.parseURL(urlText),
              let client = model.client(baseURL: url,
                                        devToken: tokenText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        do {
            let list = try await client.listConversations()
            checkResult = "Connected: \(list.count) conversation\(list.count == 1 ? "" : "s")."
        } catch {
            checkResult = error.localizedDescription
        }
    }

    private var pushLabel: String {
        switch model.notifier.pushState {
        case .offInThisBuild: return "Off in this build"
        case .notRegistered: return "Not registered yet"
        case .registering: return "Registering…"
        case .registered: return "On"
        case .failed: return "Not registered"
        }
    }

    private var notificationFooter: String {
        var text = "Parley tells you when a reply is ready to hear."
        switch model.notifier.pushState {
        case .offInThisBuild:
            text += " This build has no push (it needs a paid Apple developer team), so the notice comes only while Parley still runs in the background: shortly after you leave it, or while it plays a reply."
        case .failed(let why):
            text += " Push could not be set up: \(why)"
        default:
            break
        }
        return text
    }
}
