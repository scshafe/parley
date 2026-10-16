import SwiftData
import SwiftUI

@main
struct ParleyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @State private var player: PlayerController
    @State private var dictation: Dictation
    private let container: ModelContainer

    init() {
        let player = PlayerController()
        _player = State(initialValue: player)
        _dictation = State(initialValue: Dictation(player: player))
        container = CacheStore.makeContainer(inMemory: AppModel.isUITesting)
        AudioCache.prune(olderThanDays: 7)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(player)
                .environment(dictation)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Dictation.self) private var dictation
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var wasInBackground = false
    @State private var openTask: Task<Void, Never>?
    /// How many of the Action Button's requests this view has acted on.
    @State private var handledDictatedRequests = 0

    var body: some View {
        Group {
            if model.showsLogin {
                LoginView()
            } else {
                conversations
            }
        }
        .onChange(of: model.showsLogin) { _, showsLogin in
            if showsLogin {
                // Signed out (by the person or by an ended session): start over.
                showSettings = false
                path = NavigationPath()
            } else {
                handlePendingRoute()
            }
        }
        .onChange(of: model.dictatedConversationRequests, initial: true) { _, count in
            guard count > handledDictatedRequests else { return }
            handledDictatedRequests = count
            actionButtonPressed()
        }
        .onChange(of: scenePhase) { _, phase in
            // background -> inactive -> active: count a return from the background.
            if phase == .background {
                wasInBackground = true
                // Never record in the background: keep the words as a draft.
                if dictation.isListening { dictation.stop() }
                model.notifier.enteredBackground()
            }
            if phase == .active {
                model.notifier.becameActive()
                if wasInBackground {
                    wasInBackground = false
                    model.cameToForeground()
                }
            }
        }
        // The device token goes to the relay, again when the relay or the sign-in changes.
        .task(id: model.connectionKey) {
            model.notifier.connectionChanged()
            await model.notifier.registerWithRelay()
        }
        .onChange(of: model.pendingRoute, initial: true) { _, _ in handlePendingRoute() }
    }

    private var conversations: some View {
        NavigationStack(path: $path) {
            ConversationsView(path: $path, showSettings: $showSettings)
                .navigationDestination(for: ConversationRoute.self) { route in
                    ConversationView(conversationID: route.id, title: route.title, listenOnOpen: route.listenOnOpen,
                                     path: $path)
                }
                .navigationDestination(for: ReaderRoute.self) { route in
                    ReaderPlayerView(turn: route.turn)
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

extension RootView {
    /// The Action Button (`NewConversationIntent`). While a dictation listens,
    /// a press sends it; otherwise a new conversation opens and listens. Not
    /// signed in, the login screen stays.
    private func actionButtonPressed() {
        guard !model.showsLogin else { return }
        if dictation.isListening {
            dictation.sendNow()
            return
        }
        guard !dictation.isActive else { return }  // finishing: its message is on its way
        showSettings = false
        openTask?.cancel()
        var fresh = NavigationPath()
        fresh.append(ConversationRoute(id: nil, title: "New conversation", draft: UUID(), listenOnOpen: true))
        path = fresh
    }

    /// A tapped notification waits for the login screen to be done.
    private func handlePendingRoute() {
        guard let route = model.pendingRoute, !model.showsLogin else { return }
        model.clearPendingRoute()
        // A newer tap wins: the older one's fetch must not push its reader.
        openTask?.cancel()
        openTask = Task { await open(route) }
    }

    /// Open a tapped notification: its conversation, then the reader if the
    /// turn is ready.
    private func open(_ route: NotificationRoute) async {
        showSettings = false
        var fresh = NavigationPath()
        fresh.append(ConversationRoute(id: route.conversationID, title: "Conversation"))
        path = fresh
        guard let turnID = route.turnID, let client = model.client,
              let turn = try? await client.turn(conversationID: route.conversationID, turnID: turnID),
              turn.state == .ready, !Task.isCancelled else { return }
        path.append(ReaderRoute(turn: turn))
    }
}

struct ConversationRoute: Hashable {
    /// Nil for a new conversation that the relay makes on its first message.
    var id: String?
    var title: String
    /// Tells two new conversations apart.
    var draft: UUID?
    /// Start listening (with auto-send) when it opens: the Action Button.
    var listenOnOpen = false
}

struct ReaderRoute: Hashable {
    var turn: ParleyKitTurn
}
