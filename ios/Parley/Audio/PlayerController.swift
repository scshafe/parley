import AVFoundation
import MediaPlayer
import Observation
import ParleyKit
import QuartzCore
import UIKit

/// Plays one reply at a time and drives the follow-along highlight from the
/// audio clock (`AVAudioPlayer.currentTime`, sampled on a display link, less
/// the route's output latency while playing).
/// Background audio and lock-screen controls go through AVAudioSession,
/// MPNowPlayingInfoCenter and MPRemoteCommandCenter.
@Observable
@MainActor
final class PlayerController {
    private(set) var machine = PlaybackMachine()
    private(set) var currentMs: Int = 0
    private(set) var durationMs: Int = 0
    private(set) var position = HighlightCursor.Position(word: nil, sentence: nil)
    private(set) var turnID: String?
    private(set) var rate: Float = PlaybackSpeed.default

    var state: PlaybackState { machine.state }

    /// Called when a reply is about to load (or playback stops), so live playback of sentences yields to it.
    @ObservationIgnored var willTakeOver: (() -> Void)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var cursor: HighlightCursor?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var linkTarget: DisplayLinkTarget?
    @ObservationIgnored private var finishDelegate: FinishDelegate?
    @ObservationIgnored private var title = "Parley"
    @ObservationIgnored private var commandsInstalled = false
    /// The output latency the highlight allows for, and the last seek's time.
    @ObservationIgnored private var latencyMs = 0
    @ObservationIgnored private var seekFloorMs = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap {
                AVAudioSession.InterruptionType(rawValue: $0)
            }
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0)
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began: self.send(.interruptionBegan)
                case .ended: self.send(.interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false))
                default: break
                }
            }
        })
    }

    /// Load a ready turn's audio file and timings, replacing whatever played before.
    func load(turnID: String, audioFile: URL, timings: Timings?, title: String) {
        willTakeOver?()
        stopClock()
        player?.stop()
        player = nil
        machine = PlaybackMachine()
        self.turnID = turnID
        self.title = title
        cursor = timings.map { HighlightCursor(timings: $0) }
        seekFloorMs = 0
        currentMs = 0
        position = cursor?.position(at: 0) ?? .init(word: nil, sentence: nil)
        send(.load)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: audioFile)
            p.enableRate = true
            p.rate = rate
            p.prepareToPlay()
            let delegate = FinishDelegate { [weak self] in
                guard let self else { return }
                self.currentMs = self.durationMs
                self.stopClock()
                self.send(.reachedEnd)
            }
            p.delegate = delegate
            finishDelegate = delegate
            player = p
            durationMs = Int((p.duration * 1000).rounded())
            installRemoteCommands()
            send(.loaded)
        } catch {
            send(.loadFailed(error.localizedDescription))
        }
    }

    func failLoading(_ message: String) {
        if machine.state == .idle { send(.load) }
        send(.loadFailed(message))
    }

    func toggle() { send(.toggle) }
    func play() { send(.play) }
    func pause() { send(.pause) }

    func seek(toWord index: Int) {
        guard let ms = cursor?.seekTime(forWord: index) else { return }
        send(.seek(ms: ms))
    }

    func seek(toMs ms: Int) { send(.seek(ms: ms)) }

    func skip(seconds: Double) {
        send(.seek(ms: max(0, min(durationMs, currentMs + Int(seconds * 1000)))))
    }

    func cycleRate() { setRate(PlaybackSpeed.next(after: rate)) }

    func setRate(_ value: Float) {
        rate = PlaybackSpeed.clamp(value)
        player?.rate = rate
        updateNowPlaying()
    }

    func stop() {
        willTakeOver?()
        stopClock()
        player?.stop()
        player = nil
        turnID = nil
        machine = PlaybackMachine()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: The machine's effects

    private func send(_ event: PlaybackEvent) {
        for effect in machine.handle(event) {
            switch effect {
            case .fetchAudio:
                break  // the view fetches the file and calls load(...)
            case .startPlayer:
                guard let player else { continue }
                if !player.play() {
                    machine.handle(.pause)
                }
                startClock()
            case .pausePlayer:
                player?.pause()
                stopClock()
                tick()
            case .seekPlayer(let ms):
                player?.currentTime = Double(ms) / 1000
                seekFloorMs = ms
                tick()
            case .updateNowPlaying:
                updateNowPlaying()
            }
        }
    }

    // MARK: The clock

    private func startClock() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget { [weak self] in self?.tick() }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        linkTarget = target
        displayLink = link
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
        linkTarget = nil
    }

    private func tick() {
        guard let player else { return }
        currentMs = Int((player.currentTime * 1000).rounded())
        if let cursor {
            if machine.state == .playing {
                // Measured while playing and kept while paused, so pausing
                // leaves the highlight where the sound stopped.
                let session = AVAudioSession.sharedInstance()
                latencyMs = HighlightCursor.latencyMs(outputLatency: session.outputLatency + session.ioBufferDuration,
                                                      rate: rate)
            }
            let heard = HighlightCursor.heardMs(playerMs: currentMs, latencyMs: latencyMs, floorMs: seekFloorMs)
            let p = cursor.position(at: heard)
            if p != position { position = p }
        }
    }

    // MARK: Lock screen

    private func updateNowPlaying() {
        guard player != nil else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Parley",
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: (player?.currentTime ?? 0),
            MPNowPlayingInfoPropertyPlaybackRate: machine.state == .playing ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(seconds: -10) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(seconds: 10) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(toMs: Int(e.positionTime * 1000)) }
            return .success
        }
    }
}

private final class DisplayLinkTarget: NSObject {
    let onTick: () -> Void

    init(_ onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    @objc func step(_ link: CADisplayLink) {
        onTick()
    }
}

private final class FinishDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: @MainActor () -> Void

    init(_ onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish() }
    }
}
