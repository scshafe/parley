import ParleyKit
import SwiftData
import SwiftUI

struct ConversationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Binding var path: NavigationPath
    @Binding var showSettings: Bool
    @State private var conversations: [Conversation] = []
    @State private var cached: [CachedConversation] = []
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("conversationsError")
                }
            }
            if conversations.isEmpty && !cached.isEmpty {
                Section("Offline") {
                    ForEach(cached) { c in
                        NavigationLink(value: ConversationRoute(id: c.id, title: c.title)) {
                            Text(c.title)
                        }
                    }
                }
            }
            ForEach(conversations) { c in
                NavigationLink(value: ConversationRoute(id: c.id, title: c.displayTitle)) {
                    ConversationRow(conversation: c)
                }
                .accessibilityIdentifier("conversation-\(c.id)")
            }
        }
        .overlay {
            if conversations.isEmpty && cached.isEmpty && errorText == nil && !loading {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Start one with the + button."))
            }
        }
        .navigationTitle("Parley")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await newConversation() } } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation")
                    .accessibilityIdentifier("newConversation")
                    .disabled(!model.isConfigured)
            }
        }
        .refreshable { await reload() }
        .task(id: model.connectionKey) { await reload() }
        .onChange(of: path.count) { _, count in
            if count == 0 { Task { await reload() } }
        }
    }

    private func reload() async {
        guard let client = model.client else {
            errorText = RelayError.notConfigured.localizedDescription
            return
        }
        loading = true
        defer { loading = false }
        do {
            conversations = try await client.listConversations()
            errorText = nil
            CacheStore.save(conversations: conversations, in: context)
        } catch {
            errorText = error.localizedDescription
            cached = CacheStore.cachedConversations(in: context)
        }
    }

    private func newConversation() async {
        guard let client = model.client else { return }
        do {
            let c = try await client.createConversation()
            conversations.insert(c, at: 0)
            path.append(ConversationRoute(id: c.id, title: c.displayTitle))
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.displayTitle).font(.headline).lineLimit(1)
            if let last = conversation.lastTurn {
                HStack(spacing: 6) {
                    TurnStateBadge(state: last.state)
                    Text(last.replyText ?? last.userText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct TurnStateBadge: View {
    let state: TurnState

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .thinking, .speaking:
                ProgressView().controlSize(.mini)
            case .ready:
                Image(systemName: "speaker.wave.2.fill")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(state.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch state {
        case .thinking: return .secondary
        case .speaking: return .orange
        case .ready: return .accentColor
        case .failed: return .red
        }
    }
}
