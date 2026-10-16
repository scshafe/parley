import AppIntents

/// "New Parley Conversation": for the Action Button (Settings → Action Button
/// → Shortcut → Parley), Siri and the Shortcuts app. It opens Parley on a new
/// conversation that listens at once; the first message is sent when the
/// person pauses. Run again while Parley listens, it sends what was heard at
/// once. When not signed in, Parley opens on its login screen.
struct NewConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "New Parley Conversation"
    static let description = IntentDescription(
        "Opens Parley on a new conversation and listens. Say your first message; Parley sends it when you pause. Run it again while Parley is listening to send right away.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.requestNewDictatedConversation()
        return .result()
    }
}

struct ParleyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewConversationIntent(),
                    phrases: [
                        "New \(.applicationName) conversation",
                        "Start a \(.applicationName) conversation",
                        "Talk to \(.applicationName)",
                    ],
                    shortTitle: "New Conversation",
                    systemImageName: "mic.fill")
    }
}
