import ParleyKit
import SwiftData
import SwiftUI

/// A conversation: its turns, each with its state and a play button, and the
/// composer. Turn states arrive on the relay's event stream; when the stream is
/// down the view polls while a turn is unfinished.
struct ConversationView: View {
    let conversationID: String
    let title: String
    @Binding var path: NavigationPath
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var turns: [ParleyKit.Turn] = []
    @State private var lastEventID = 0
    @State private var draft = ""
    @State private var sending = false
    @State private var pendingClientTurnID: String?
    @State private var errorText: String?
    @State private var liveTitle: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if turns.isEmpty {
                        Text("Say something to start. Replies come back in your voice.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(turns) { turn in
                        TurnRow(turn: turn) {
                            path.append(ReaderRoute(turn: turn))
                        }
                        .id(turn.id)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("conversationError")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: turns.last?.state) { _, _ in
                if let id = turns.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(liveTitle ?? title)
        .navigationBarTitleDisplayMode(.inline)
        // Reconnects when the relay, the sign-in or its access token changes,
        // and when the app comes back to the foreground.
        .task(id: model.streamKey) { await follow() }
        .onAppear { model.notifier.visibleConversationID = conversationID }
        .onDisappear {
            if model.notifier.visibleConversationID == conversationID { model.notifier.visibleConversationID = nil }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .submitLabel(.send)
                .accessibilityIdentifier("composerField")
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("sendButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Sending

    private func send() async {
        guard let client = model.client else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // The same client turn id is reused until the send succeeds, so a retry
        // after a dropped connection cannot make a second turn.
        let ctid = pendingClientTurnID ?? makeClientTurnID()
        pendingClientTurnID = ctid
        sending = true
        defer { sending = false }
        do {
            let turn = try await client.sendTurn(conversationID: conversationID, text: text, clientTurnID: ctid)
            pendingClientTurnID = nil
            draft = ""
            errorText = nil
            merge(turn)
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Following the conversation

    private func merge(_ turn: ParleyKit.Turn) {
        if let i = turns.firstIndex(where: { $0.id == turn.id }) {
            // Keep the newest: events can arrive out of order with a fetch.
            if turns[i].updatedAt <= turn.updatedAt { turns[i] = turn }
        } else {
            turns.append(turn)
            turns.sort { $0.seq < $1.seq }
        }
        CacheStore.save(turns: [turn], in: context)
        model.notifier.observe(turn)
    }

    private func refresh(_ client: RelayClient) async throws {
        let conv = try await client.conversation(id: conversationID)
        for t in conv.turns ?? [] { merge(t) }
        lastEventID = max(lastEventID, conv.lastEventId)
        liveTitle = conv.displayTitle
        errorText = nil
    }

    private func follow() async {
        turns = CacheStore.cachedTurns(conversationID: conversationID, in: context)
        guard let client = model.client else { return }
        while !Task.isCancelled {
            do {
                try await refresh(client)
                for try await event in client.events(conversationID: conversationID, after: lastEventID) {
                    if let id = event.id { lastEventID = id }
                    if let turn = event.turn {
                        merge(turn)
                        if liveTitle == nil || liveTitle == "New conversation", turn.seq == 1 {
                            liveTitle = String(turn.userText.prefix(60))
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if let e = error as? RelayError, [.signInRequired, .unauthorized, .notConfigured].contains(e) {
                    // Retrying cannot help; a new sign-in or token restarts this task.
                    errorText = e.localizedDescription
                    return
                }
                // The stream is down: poll while something is unfinished.
                try? await Task.sleep(for: .seconds(2))
                try? await refresh(client)
            }
        }
    }
}

struct TurnRow: View {
    let turn: ParleyKit.Turn
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.userText)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TurnStateBadge(state: turn.state)
                        .accessibilityIdentifier("turnState-\(turn.seq)")
                        .accessibilityValue(turn.state.rawValue)
                    Spacer()
                    if turn.state == .ready {
                        Button(action: onPlay) {
                            Label("Play", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("playTurn-\(turn.seq)")
                    }
                }
                if let reply = turn.replyText {
                    Text(reply).lineLimit(turn.state == .ready ? 4 : nil)
                } else if turn.state == .thinking {
                    Text("Thinking…").foregroundStyle(.secondary)
                }
                if let error = turn.error {
                    Text(error.detail.isEmpty ? error.code : error.detail)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
