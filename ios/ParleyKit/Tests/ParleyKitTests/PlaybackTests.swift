import XCTest
@testable import ParleyKit

final class PlaybackTests: XCTestCase {
    func testSpeedsCycleWithinTheRange() {
        XCTAssertEqual(PlaybackSpeed.next(after: 1.0), 1.25)
        XCTAssertEqual(PlaybackSpeed.next(after: 1.5), 0.75)
        XCTAssertEqual(PlaybackSpeed.next(after: 0.75), 1.0)
        XCTAssertEqual(PlaybackSpeed.clamp(3), 1.5)
        XCTAssertEqual(PlaybackSpeed.clamp(0.1), 0.75)
        XCTAssertEqual(PlaybackSpeed.label(1.0), "1×")
        XCTAssertEqual(PlaybackSpeed.label(1.5), "1.5×")
        XCTAssertEqual(PlaybackSpeed.label(0.75), "0.75×")
    }

    func testLoadPlayPauseFinish() {
        var m = PlaybackMachine()
        XCTAssertEqual(m.handle(.play), [])
        XCTAssertEqual(m.handle(.load), [.fetchAudio])
        XCTAssertEqual(m.state, .loading)
        XCTAssertEqual(m.handle(.loaded), [.updateNowPlaying])
        XCTAssertEqual(m.handle(.toggle), [.startPlayer, .updateNowPlaying])
        XCTAssertTrue(m.state.isPlaying)
        XCTAssertEqual(m.handle(.seek(ms: 1200)), [.seekPlayer(ms: 1200), .updateNowPlaying])
        XCTAssertEqual(m.handle(.pause), [.pausePlayer, .updateNowPlaying])
        XCTAssertEqual(m.state, .paused)
        _ = m.handle(.play)
        XCTAssertEqual(m.handle(.reachedEnd), [.updateNowPlaying])
        XCTAssertEqual(m.state, .finished)
        // Play again from the start.
        XCTAssertEqual(m.handle(.play), [.seekPlayer(ms: 0), .startPlayer, .updateNowPlaying])
    }

    func testSeekAfterTheEndPausesThere() {
        var m = PlaybackMachine()
        _ = m.handle(.load); _ = m.handle(.loaded); _ = m.handle(.play); _ = m.handle(.reachedEnd)
        XCTAssertEqual(m.handle(.seek(ms: -5)), [.seekPlayer(ms: 0), .updateNowPlaying])
        XCTAssertEqual(m.state, .paused)
    }

    func testLoadFailureAndRetry() {
        var m = PlaybackMachine()
        _ = m.handle(.load)
        _ = m.handle(.loadFailed("offline"))
        XCTAssertEqual(m.state, .failed("offline"))
        XCTAssertEqual(m.handle(.play), [])
        XCTAssertEqual(m.handle(.load), [.fetchAudio])
    }

    func testInterruptionResumesOnlyWhenItPausedPlayback() {
        var m = PlaybackMachine()
        _ = m.handle(.load); _ = m.handle(.loaded); _ = m.handle(.play)
        XCTAssertEqual(m.handle(.interruptionBegan), [.pausePlayer, .updateNowPlaying])
        XCTAssertEqual(m.handle(.interruptionEnded(shouldResume: true)), [.startPlayer, .updateNowPlaying])
        _ = m.handle(.pause)
        XCTAssertEqual(m.handle(.interruptionEnded(shouldResume: true)), [])
        XCTAssertEqual(m.state, .paused)
    }
}
