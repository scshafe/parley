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

    var body: some View {
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
        .onAppear {
            if !model.isConfigured { showSettings = true }
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
        .task(id: model.connectionKey) { await model.notifier.registerWithRelay() }
        .onChange(of: model.pendingRoute, initial: true) { _, route in
            guard let route else { return }
            model.clearPendingRoute()
            Task { await open(route) }
        }
    }
}

extension RootView {
    /// Open a tapped notification: its conversation, then the reader if the
    /// turn is ready.
    private func open(_ route: NotificationRoute) async {
        showSettings = false
        var fresh = NavigationPath()
        fresh.append(ConversationRoute(id: route.conversationID, title: "Conversation"))
        path = fresh
        guard let turnID = route.turnID, let client = model.client,
              let turn = try? await client.turn(conversationID: route.conversationID, turnID: turnID),
              turn.state == .ready else { return }
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
