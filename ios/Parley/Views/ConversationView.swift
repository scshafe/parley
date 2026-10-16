import ParleyKit
import SwiftData
import SwiftUI

/// A conversation: its turns, each with its state and a play button, and the
/// composer (typed, or dictated with the mic). Turn states arrive on the
/// relay's event stream; when the stream is down the view polls while a turn
/// is unfinished.
///
/// A new conversation from the Action Button has no id yet: the relay makes it
/// when its first message is sent, and the view listens from the start.
struct ConversationView: View {
    let title: String
    let listenOnOpen: Bool
    @Binding var path: NavigationPath
    @Environment(AppModel.self) private var model
    @Environment(Dictation.self) private var dictation
    @Environment(\.modelContext) private var context
    @State private var conversationID: String?
    @State private var turns: [ParleyKit.Turn] = []
    @State private var lastEventID = 0
    @State private var draft = ""
    @State private var sending = false
    @State private var pendingClientTurnID: String?
    @State private var errorText: String?
    @State private var liveTitle: String?
    /// Who this view is, for the dictation it starts.
    @State private var dictationOwner = UUID()
    /// The draft as it was when dictation started; the words go after it.
    @State private var draftBeforeDictation = ""
    @State private var listenedOnOpen = false
    @FocusState private var composerFocused: Bool

    init(conversationID: String?, title: String, listenOnOpen: Bool = false, path: Binding<NavigationPath>) {
        _conversationID = State(initialValue: conversationID)
        self.title = title
        self.listenOnOpen = listenOnOpen
        _path = path
    }

    private var isMyDictation: Bool { dictation.isActive && dictation.ownerID == dictationOwner }

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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if isMyDictation { listeningBar }
                composer
            }
        }
        .navigationTitle(liveTitle ?? title)
        .navigationBarTitleDisplayMode(.inline)
        // Reconnects when the relay, the sign-in or its access token changes,
        // when the app comes back to the foreground, and once a new
        // conversation has its id.
        .task(id: "\(model.streamKey)|\(conversationID ?? "")") { await follow() }
        .onChange(of: dictation.transcript) { _, words in
            if isMyDictation && !words.isEmpty { draft = LiveTranscript.join(draftBeforeDictation, words) }
        }
        .onChange(of: conversationID) { _, id in model.notifier.visibleConversationID = id }
        .onAppear {
            model.notifier.visibleConversationID = conversationID
            if listenOnOpen && !listenedOnOpen {
                listenedOnOpen = true
                startDictation(autoSend: true)
            }
        }
        .onDisappear {
            if model.notifier.visibleConversationID == conversationID { model.notifier.visibleConversationID = nil }
            dictation.ownerDisappeared(dictationOwner)
        }
    }

    // MARK: Dictation

    private var listeningBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, isActive: dictation.isListening)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(listeningTitle)
                    .font(.subheadline.weight(.semibold))
                Text(listeningHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("listeningIndicator")
            Spacer()
            Button("Cancel", role: .cancel) { dictation.cancel(); draft = draftBeforeDictation }
                .accessibilityIdentifier("dictationCancel")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var listeningTitle: String {
        if let status = dictation.status { return status }
        switch dictation.machine.phase {
        case .starting: return "Starting the microphone…"
        case .finishing(let send): return send ? "Sending…" : "Finishing…"
        default: return "Listening…"
        }
    }

    private var listeningHint: String {
        dictation.autoSend
            ? "Sends when you pause. Press the Action Button or Send to send now."
            : "Tap the mic to stop, or Send."
    }

    private func startDictation(autoSend: Bool) {
        composerFocused = false
        errorText = nil
        draftBeforeDictation = draft
        dictation.start(autoSend: autoSend, owner: dictationOwner, onSend: { text in
            draft = LiveTranscript.join(draftBeforeDictation, text)
            Task { await send() }
        }, onKeepDraft: { text in
            draft = LiveTranscript.join(draftBeforeDictation, text)
        }, onFailure: { why in
            errorText = why
        })
    }

    private func micTapped() {
        if isMyDictation {
            dictation.stop()
        } else {
            startDictation(autoSend: false)
        }
    }

    /// Send: while dictating, finish and send what was heard (with what was
    /// typed before it); otherwise send the draft.
    private func sendTapped() {
        if isMyDictation && dictation.isListening && !dictation.transcript.isEmpty {
            dictation.sendNow()
            return
        }
        if isMyDictation { dictation.cancel() }
        Task { await send() }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: micTapped) {
                Image(systemName: isMyDictation ? "stop.circle.fill" : "mic.circle")
                    .font(.title)
                    .foregroundStyle(isMyDictation ? Color.red : Color.accentColor)
            }
            .disabled(sending || (dictation.isActive && !isMyDictation))
            .accessibilityLabel(isMyDictation ? "Stop dictation" : "Dictate")
            .accessibilityIdentifier("micButton")
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .submitLabel(.send)
                .disabled(isMyDictation)
                .accessibilityIdentifier("composerField")
            Button(action: sendTapped) {
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
        guard let client = model.client else {
            errorText = model.configurationProblem ?? RelayError.notConfigured.localizedDescription
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        // The same client turn id is reused until the send succeeds, so a retry
        // after a dropped connection cannot make a second turn.
        let ctid = pendingClientTurnID ?? makeClientTurnID()
        pendingClientTurnID = ctid
        sending = true
        defer { sending = false }
        do {
            // A new conversation is made on its first message (kept if the turn then fails).
            let id: String
            if let conversationID {
                id = conversationID
            } else {
                id = try await client.createConversation().id
                conversationID = id
            }
            let turn = try await client.sendTurn(conversationID: id, text: text, clientTurnID: ctid)
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

    private func refresh(_ client: RelayClient, _ conversationID: String) async throws {
        let conv = try await client.conversation(id: conversationID)
        for t in conv.turns ?? [] { merge(t) }
        lastEventID = max(lastEventID, conv.lastEventId)
        liveTitle = conv.displayTitle
        errorText = nil
    }

    private func follow() async {
        guard let conversationID else { return }
        if turns.isEmpty { turns = CacheStore.cachedTurns(conversationID: conversationID, in: context) }
        guard let client = model.client else { return }
        while !Task.isCancelled {
            do {
                try await refresh(client, conversationID)
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
                try? await refresh(client, conversationID)
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
