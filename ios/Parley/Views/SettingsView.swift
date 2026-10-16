import ParleyKit
import SwiftData
import SwiftUI
import UserNotifications

/// The account (who is signed in, Sign out), the relay URL, notification
/// permission and the version. Signing in happens on the login screen.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PlayerController.self) private var player
    @State private var urlText = ""
    @State private var checkResult: String?
    @State private var urlProblem: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                Section {
                    TextField("https://parley.example.ts.net", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: urlText) { _, _ in
                            urlProblem = nil
                            checkResult = nil
                        }
                        .accessibilityIdentifier("relayURLField")
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Text("Check connection")
                            if checking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(checking || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("checkConnection")
                    if let urlProblem {
                        Text(urlProblem).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("relayProblem")
                    }
                    if let checkResult {
                        Text(checkResult).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("checkResult")
                    }
                } header: {
                    Text("Relay")
                } footer: {
                    Text(relayFooter)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("settingsCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if save() { dismiss() } }
                        .accessibilityIdentifier("settingsDone")
                }
            }
            .onAppear {
                urlText = model.relayURLString
            }
            .task { await model.notifier.refreshAuthorization() }
        }
    }

    private var accountSection: some View {
        Section {
            LabeledContent("Signed in as", value: model.account?.label ?? "you")
                .accessibilityIdentifier("accountLabel")
            Button("Sign out", role: .destructive) { Task { await signOut() } }
                .accessibilityIdentifier("signOutButton")
        } header: {
            Text("Account")
        } footer: {
            Text(accountFooter)
        }
    }

    private var accountFooter: String {
        guard let issuer = model.oidcConfiguration?.issuer.host else { return "" }
        return "Signed in with Pocket ID (\(issuer)). Signing out forgets the session and this phone's copy of your conversations and replies."
    }

    private var relayFooter: String {
        let suffix = model.relayHostSuffix
        guard !suffix.isEmpty else { return "The relay's address on your tailnet." }
        let shown = suffix.hasPrefix(".") ? "*" + suffix : "*." + suffix
        return "The relay's address on your tailnet. Your sign-in is sent only over https to a relay under \(shown)."
    }

    private var notificationLabel: String {
        switch model.notifier.authorization {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Off (change it in Settings)"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    /// Save the relay URL if it changed and may carry the sign-in; otherwise
    /// say why and stay open.
    private func save() -> Bool {
        let typed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed == model.relayURLString { return true }
        switch model.validate(relayURL: typed) {
        case .success(let url):
            model.update(relayURL: url)
            return true
        case .failure(let problem):
            urlProblem = problem.localizedDescription
            return false
        }
    }

    /// Sign out, and forget what this phone kept of the relay: the cached
    /// conversations and the reply audio. The app goes back to the login screen.
    private func signOut() async {
        player.stop()
        await model.signOut()
        CacheStore.removeAll(in: context)
        AudioCache.removeAll()
        checkResult = nil
    }

    private func check() async {
        checkResult = nil
        let url: URL
        switch model.validate(relayURL: urlText) {
        case .success(let u): url = u
        case .failure(let problem):
            urlProblem = problem.localizedDescription
            return
        }
        guard let client = model.client(baseURL: url) else {
            urlProblem = RelayError.signInRequired.localizedDescription
            return
        }
        checking = true
        defer { checking = false }
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
        case .registered(let relayCanPush): return relayCanPush ? "On" : "Registered (the relay cannot push yet)"
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
