import ParleyKit
import SwiftData
import SwiftUI

/// The reader-player: the reply's text with the heard word highlighted and its
/// sentence tinted, following the audio clock. Tap a word to seek to it.
struct ReaderPlayerView: View {
    let turn: ParleyKit.Turn
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(\.modelContext) private var context
    @State private var timings: Timings?
    @State private var tokens: [ReaderToken] = []
    @State private var loadError: String?

    private var text: String { turn.replyText ?? "" }
    private var isCurrent: Bool { player.turnID == turn.id }
    private var position: HighlightCursor.Position {
        isCurrent ? player.position : .init(word: nil, sentence: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        FlowLayout(lineSpacing: 6) {
                            ForEach(tokens) { token in
                                tokenView(token)
                                    .id(token.id)
                                    .layoutValue(key: LineBreakAfter.self, value: token.breaksLine)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("readerText")
                        if let attachment = turn.attachment {
                            AttachmentView(text: attachment)
                        }
                    }
                    .padding()
                }
                .onChange(of: position.word) { _, word in
                    guard let word, let token = tokens.first(where: { $0.word == word }) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(token.id, anchor: .center) }
                }
            }
            controls
        }
        .navigationTitle("Reply")
        .navigationBarTitleDisplayMode(.inline)
        .task { await prepare() }
        .onDisappear { if isCurrent { player.pause() } }
    }

    private func tokenView(_ token: ReaderToken) -> some View {
        let isWord = token.word != nil && token.word == position.word
        let inSentence = token.sentence != nil && token.sentence == position.sentence
        return HStack(spacing: 0) {
            Text(token.core)
                .foregroundStyle(isWord ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 4).fill(isWord ? Color.accentColor : Color.clear)
                    .padding(.horizontal, -2))
            Text(token.trail)
        }
        .font(.title3)
        .padding(.vertical, 1)
        .background(inSentence ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if let w = token.word, isCurrent { player.seek(toWord: w) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(token.word != nil ? .isButton : [])
        .accessibilityIdentifier(token.word.map { "word-\($0)" } ?? "text-\(token.id)")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("readerError")
            }
            let duration = max(1, isCurrent ? player.durationMs : (turn.audio?.durationMs ?? 1))
            Slider(value: Binding(
                get: { Double(isCurrent ? min(player.currentMs, duration) : 0) },
                set: { player.seek(toMs: Int($0)) }
            ), in: 0...Double(duration))
            .disabled(!isCurrent)
            .accessibilityIdentifier("progress")
            HStack {
                Text(clock(isCurrent ? player.currentMs : 0)).monospacedDigit()
                Spacer()
                Text(statusLine)
                    .accessibilityIdentifier("highlightProbe")
                    .accessibilityValue(position.word.map(String.init) ?? "none")
                Spacer()
                Text(clock(duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 36) {
                Button { player.skip(seconds: -10) } label: { Image(systemName: "gobackward.10") }
                    .accessibilityLabel("Back 10 seconds")
                Button { player.toggle() } label: {
                    Image(systemName: player.state.isPlaying && isCurrent ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 54))
                }
                .accessibilityLabel(player.state.isPlaying && isCurrent ? "Pause" : "Play")
                .accessibilityIdentifier("playPauseButton")
                .disabled(!isCurrent)
                Button { player.skip(seconds: 10) } label: { Image(systemName: "goforward.10") }
                    .accessibilityLabel("Forward 10 seconds")
                Button { player.cycleRate() } label: {
                    Text(PlaybackSpeed.label(player.rate)).font(.callout.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 48)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Speed \(PlaybackSpeed.label(player.rate))")
                .accessibilityIdentifier("speedButton")
            }
            .font(.title2)
        }
        .padding()
        .background(.bar)
    }

    private var statusLine: String {
        guard let t = timings, let s = position.sentence else {
            return player.state == .loading ? "Loading…" : " "
        }
        return "Sentence \(s + 1) of \(t.sentences.count)"
    }

    private func clock(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Loading

    private func prepare() async {
        if let cached = CacheStore.timings(turnID: turn.id, in: context),
           let t = try? Timings.decode(cached, for: text) {
            timings = t
        }
        tokens = ReaderLayout.tokens(text: text, timings: timings)
        if isCurrent { return }
        guard let client = model.client else {
            loadError = "Set the relay in Settings."
            return
        }
        do {
            if timings == nil {
                let data = try await client.timingsData(for: turn)
                timings = try Timings.decode(data, for: text)
                CacheStore.save(timings: data, turnID: turn.id, in: context)
                tokens = ReaderLayout.tokens(text: text, timings: timings)
            }
            let file = AudioCache.file(for: turn.id)
            if !FileManager.default.fileExists(atPath: file.path) {
                try await client.downloadAudio(for: turn, to: file)
            }
            player.load(turnID: turn.id, audioFile: file, timings: timings, title: turn.userText)
            player.play()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct AttachmentView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("On screen", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
            Text(LocalizedStringKey(linkified))
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("attachment")
    }

    /// Bare URLs become tappable links (Text renders inline markdown links).
    private var linkified: String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            if (s.hasPrefix("https://") || s.hasPrefix("http://")) && !s.contains(" ") {
                return "[\(s)](\(s))"
            }
            return s
        }.joined(separator: "\n")
    }
}

/// Lays tokens out like text: left to right, wrapping at the width, and
/// starting a new line after a token that ends one.
struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Item { var index: Int; var x: CGFloat; var size: CGSize }
    private struct Row { var y: CGFloat; var height: CGFloat; var items: [Item] }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, items: [])
        var x: CGFloat = 0
        func newRow() {
            let y = current.items.isEmpty && rows.isEmpty ? 0 : current.y + current.height + lineSpacing
            if !current.items.isEmpty || !rows.isEmpty { rows.append(current) }
            current = Row(y: y, height: 0, items: [])
            x = 0
        }
        for (i, sub) in subviews.enumerated() {
            var size = sub.sizeThatFits(.unspecified)
            if size.width > width { size = sub.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + size.width > width { newRow() }
            current.items.append(Item(index: i, x: x, size: size))
            current.height = max(current.height, size.height)
            x += size.width
            if sub[LineBreakAfter.self] { newRow() }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

struct LineBreakAfter: LayoutValueKey {
    static let defaultValue = false
}
