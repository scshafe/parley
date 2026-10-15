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
    @State private var path = NavigationPath()
    @State private var showSettings = false

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
    }
}

struct ConversationRoute: Hashable {
    var id: String
    var title: String
}

struct ReaderRoute: Hashable {
    var turn: ParleyKitTurn
}
