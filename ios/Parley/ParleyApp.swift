import SwiftData
import SwiftUI

@main
struct ParleyApp: App {
    @State private var model = AppModel()
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
            if phase == .background { wasInBackground = true }
            if phase == .active && wasInBackground {
                wasInBackground = false
                model.cameToForeground()
            }
        }
    }
}

struct ConversationRoute: Hashable {
    var id: String
    var title: String
}

struct ReaderRoute: Hashable {
    var turn: ParleyKitTurn
}
