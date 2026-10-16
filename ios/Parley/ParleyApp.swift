import SwiftData
import SwiftUI

@main
struct ParleyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @State private var player = PlayerController()
    private let container: ModelContainer

    init() {
        container = CacheStore.makeContainer(inMemory: AppModel.isUITesting)
        AudioCache.prune(olderThanDays: 7)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(player)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var wasInBackground = false
    @State private var openTask: Task<Void, Never>?

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
        .onChange(of: scenePhase) { _, phase in
            // background -> inactive -> active: count a return from the background.
            if phase == .background {
                wasInBackground = true
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
                    ConversationView(conversationID: route.id, title: route.title, path: $path)
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
    var id: String
    var title: String
}

struct ReaderRoute: Hashable {
    var turn: ParleyKitTurn
}
