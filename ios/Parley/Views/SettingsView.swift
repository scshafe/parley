import ParleyKit
import SwiftUI
import UserNotifications

/// The relay URL, the dev token (P1; Pocket ID sign-in replaces it in P2), and
/// notification permission (push arrives in P2).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var checkResult: String?
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
                    SecureField("Token", text: $tokenText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("tokenField")
                    Button("Check connection") { Task { await check() } }
                        .disabled(RelayConfiguration.parseURL(urlText) == nil || tokenText.isEmpty)
                    if let checkResult {
                        Text(checkResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Relay")
                } footer: {
                    Text("The relay's address on your tailnet, and its token. The token stays in this phone's Keychain.")
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
                tokenText = model.token
            }
            .task { await refreshNotificationStatus() }
        }
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
                     token: tokenText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func check() async {
        guard let url = RelayConfiguration.parseURL(urlText) else { return }
        let client = RelayClient(configuration: RelayConfiguration(baseURL: url, token: tokenText))
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
