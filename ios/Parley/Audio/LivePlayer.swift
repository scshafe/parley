import AVFoundation
import Observation
import ParleyKit

/// Plays a reply from its first sentence while the rest is still being
/// spoken. The relay lists each sentence's audio as voice-lab finishes it
/// (`Turn.segments`); this downloads them in order and queues them. There is no
/// word highlight: that needs the whole reply, and the reader-player has it
/// once the turn is ready. Starting a reply in the reader stops this.
@Observable
@MainActor
final class LivePlayer {
    private(set) var turnID: String?
    /// Whether it is meant to be playing (false while paused by the person).
    private(set) var isPlaying = false

    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private var queue: AVQueuePlayer?
    @ObservationIgnored private var turn: ParleyKit.Turn?
    @ObservationIgnored private var client: RelayClient?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var queued = 0
    @ObservationIgnored private var played = 0
    @ObservationIgnored private var files: [URL] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(player: PlayerController) {
        self.player = player
        player.willTakeOver = { [weak self] in self?.stop() }
    }

    /// Whether the person can start this turn live: it has a sentence to play.
    static func canListen(_ turn: ParleyKit.Turn) -> Bool {
        turn.state == .speaking && !(turn.segments ?? []).isEmpty
    }

    func start(turn: ParleyKit.Turn, client: RelayClient) {
        stop()
        player.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            return
        }
        let queue = AVQueuePlayer()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemFinished() }
        }
        self.queue = queue
        self.client = client
        self.turn = turn
        turnID = turn.id
        isPlaying = true
        pump()
    }

    /// A newer version of the turn arrived: queue any new sentences.
    func update(_ newer: ParleyKit.Turn) {
        guard newer.id == turnID else { return }
        turn = newer
        pump()
        finishIfDone()
    }

    func toggle() {
        guard let queue else { return }
        isPlaying.toggle()
        if isPlaying { queue.play() } else { queue.pause() }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        queue?.pause()
        queue?.removeAllItems()
        queue = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
        queued = 0
        played = 0
        turn = nil
        client = nil
        turnID = nil
        isPlaying = false
    }

    // MARK: Queueing

    private func nextSegment() -> TurnSegment? {
        turn?.segments?.first { $0.index == queued + 1 }
    }

    /// One worker downloads the sentences in order. Nothing suspends between
    /// finding no next sentence and clearing `worker`, so `update` cannot miss one.
    private func pump() {
        guard worker == nil, queue != nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, let segment = self.nextSegment(), let client = self.client,
                  let turnID = self.turnID {
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("live-\(turnID)-\(segment.index).wav")
                do {
                    try await client.downloadSegment(segment, to: file)
                } catch {
                    if !Task.isCancelled { self.stop() }
                    return
                }
                guard !Task.isCancelled, self.turnID == turnID else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                self.files.append(file)
                self.queue?.insert(AVPlayerItem(url: file), after: nil)
                self.queued += 1
                if self.isPlaying { self.queue?.play() }  // a queue that ran dry needs it again
            }
            self?.worker = nil
        }
    }

    private func itemFinished() {
        played += 1
        finishIfDone()
    }

    /// Everything heard and nothing more is coming: the turn is no longer speaking.
    private func finishIfDone() {
        guard turn != nil, played >= queued, worker == nil, nextSegment() == nil,
              turn?.state != .speaking, turn?.state != .thinking else { return }
        stop()
    }
}
