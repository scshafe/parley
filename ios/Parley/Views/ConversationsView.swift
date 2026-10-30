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
    @State private var query = ""
    @State private var results: [Conversation] = []
    @State private var searchError: String?

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            if let errorText {
                Section {
                    SuiBanner(text: errorText, tone: .warning, symbol: "wifi.exclamationmark")
                        .accessibilityIdentifier("conversationsError")
                }
            }
            if searching {
                if let searchError {
                    SuiBanner(text: searchError, tone: .warning, symbol: "wifi.exclamationmark")
                }
                ForEach(results) { c in
                    NavigationLink(value: ConversationRoute(id: c.id, title: c.displayTitle)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.displayTitle).font(.headline).lineLimit(1)
                            if let snippet = c.snippet {
                                Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .accessibilityIdentifier("result-\(c.id)")
                }
            } else if conversations.isEmpty && !cached.isEmpty {
                Section("Offline") {
                    ForEach(cached) { c in
                        NavigationLink(value: ConversationRoute(id: c.id, title: c.title)) {
                            Text(c.title)
                        }
                    }
                }
            }
            if !searching {
                ForEach(conversations) { c in
                    NavigationLink(value: ConversationRoute(id: c.id, title: c.displayTitle)) {
                        ConversationRow(conversation: c)
                    }
                    .accessibilityIdentifier("conversation-\(c.id)")
                }
            }
        }
        .searchable(text: $query, prompt: "Search conversations")
        .task(id: query) { await search() }
        .overlay {
            if searching && results.isEmpty && searchError == nil {
                ContentUnavailableView.search(text: query)
            } else if !searching && conversations.isEmpty && cached.isEmpty && errorText == nil && !loading {
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

    /// Runs after a short pause, so typing does not send a request per letter.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let client = model.client else {
            results = []
            searchError = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            results = try await client.searchConversations(text)
            searchError = nil
        } catch is CancellationError {
        } catch {
            results = []
            searchError = error.localizedDescription
        }
    }

    private func reload() async {
        guard let client = model.client else {
            errorText = model.configurationProblem ?? RelayError.notConfigured.localizedDescription
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
            case .thinking:
                Image(systemName: "ellipsis")
            case .speaking:
                Image(systemName: "waveform")
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
        case .thinking: return SuiTone.neutral.color
        case .speaking: return SuiTone.warning.color
        case .ready: return SuiTone.info.color
        case .failed: return SuiTone.danger.color
        }
    }
}
