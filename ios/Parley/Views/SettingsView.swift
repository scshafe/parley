import AuthenticationServices
import ParleyKit
import SwiftUI
import UserNotifications

/// The relay URL, signing in with Pocket ID (or a dev relay's token), and
/// notification permission.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var checkResult: String?
    @State private var signInError: String?
    @State private var signingIn = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

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
                    if notificationStatus == .notDetermined {
                        Button("Allow notifications") { Task { await requestNotifications() } }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Parley will tell you when a reply is ready to hear. Push arrives in a later version; for now the app follows turns while it is open.")
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
            .task { await refreshNotificationStatus() }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if model.isSignedIn {
                LabeledContent("Signed in as", value: model.account?.label ?? "you")
                    .accessibilityIdentifier("accountLabel")
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
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

    private var canAuthenticate: Bool {
        !tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSignedIn
    }

    private var notificationLabel: String {
        switch notificationStatus {
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

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotificationStatus()
    }
}
