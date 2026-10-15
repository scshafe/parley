import Foundation

/// The reader-player's playback speeds: 0.75x to 1.5x.
public enum PlaybackSpeed {
    public static let all: [Float] = [0.75, 1.0, 1.25, 1.5]
    public static let `default`: Float = 1.0

    public static func clamp(_ rate: Float) -> Float {
        min(max(rate, all.first!), all.last!)
    }

    /// The next speed in the cycle, wrapping from the fastest to the slowest.
    public static func next(after rate: Float) -> Float {
        if let i = all.firstIndex(where: { $0 > rate + 0.001 }) { return all[i] }
        return all[0]
    }

    public static func label(_ rate: Float) -> String {
        let r = clamp(rate)
        if r == r.rounded() { return String(format: "%.0f×", r) }
        if (r * 10) == (r * 10).rounded() { return String(format: "%.1f×", r) }
        return String(format: "%.2f×", r)
    }
}

/// The player's state machine, kept free of AVFoundation so it is tested on
/// its own. The app's player feeds it events and performs the effects.
public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case finished
    case failed(String)

    public var isPlaying: Bool { self == .playing }
}

public enum PlaybackEvent: Equatable, Sendable {
    case load
    case loaded
    case loadFailed(String)
    case play
    case pause
    case toggle
    case seek(ms: Int)
    case reachedEnd
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
}

public enum PlaybackEffect: Equatable, Sendable {
    case fetchAudio
    case startPlayer
    case pausePlayer
    case seekPlayer(ms: Int)
    case updateNowPlaying
}

public struct PlaybackMachine: Equatable, Sendable {
    public private(set) var state: PlaybackState = .idle
    /// Set when an interruption (a call) paused playback, so it can resume after.
    public private(set) var resumeAfterInterruption = false

    public init() {}

    @discardableResult
    public mutating func handle(_ event: PlaybackEvent) -> [PlaybackEffect] {
        switch (state, event) {
        case (.idle, .load), (.failed, .load):
            state = .loading
            return [.fetchAudio]
        case (.loading, .loaded):
            state = .ready
            return [.updateNowPlaying]
        case (.loading, .loadFailed(let why)):
            state = .failed(why)
            return []
        case (.ready, .play), (.paused, .play), (.ready, .toggle), (.paused, .toggle):
            state = .playing
            return [.startPlayer, .updateNowPlaying]
        case (.finished, .play), (.finished, .toggle):
            state = .playing
            return [.seekPlayer(ms: 0), .startPlayer, .updateNowPlaying]
        case (.playing, .pause), (.playing, .toggle):
            state = .paused
            return [.pausePlayer, .updateNowPlaying]
        case (.playing, .reachedEnd):
            state = .finished
            return [.updateNowPlaying]
        case (.playing, .seek(let ms)), (.paused, .seek(let ms)), (.ready, .seek(let ms)):
            return [.seekPlayer(ms: max(0, ms)), .updateNowPlaying]
        case (.finished, .seek(let ms)):
            state = .paused
            return [.seekPlayer(ms: max(0, ms)), .updateNowPlaying]
        case (.playing, .interruptionBegan):
            state = .paused
            resumeAfterInterruption = true
            return [.pausePlayer, .updateNowPlaying]
        case (.paused, .interruptionEnded(let shouldResume)):
            let resume = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            if resume {
                state = .playing
                return [.startPlayer, .updateNowPlaying]
            }
            return []
        default:
            return []
        }
    }
}
