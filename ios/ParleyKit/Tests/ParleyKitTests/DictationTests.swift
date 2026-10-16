import XCTest
@testable import ParleyKit

final class DictationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A machine that is listening, started at t0.
    private func listening(autoSend: Bool) -> DictationMachine {
        var m = DictationMachine()
        XCTAssertEqual(m.handle(.start(autoSend: autoSend, at: t0)), [.startListening])
        XCTAssertEqual(m.phase, .starting)
        XCTAssertEqual(m.handle(.started(at: t0)), [])
        XCTAssertEqual(m.phase, .listening)
        return m
    }

    func testAutoSendWaitsForSilenceAfterSpeech() {
        var m = listening(autoSend: true)
        // Silence before any word never sends.
        XCTAssertEqual(m.handle(.tick(at: at(5))), [])
        XCTAssertEqual(m.handle(.transcript("What should", at: at(6))), [])
        XCTAssertEqual(m.handle(.tick(at: at(7))), [])
        XCTAssertEqual(m.handle(.transcript("What should I cook", at: at(7.5))), [])
        // Under the silence interval since the last new word: still listening.
        XCTAssertEqual(m.handle(.tick(at: at(7.5 + DictationMachine.silenceToSend - 0.1))), [])
        // The same text again is not a new word.
        XCTAssertEqual(m.handle(.transcript("What should I cook", at: at(8.5))), [])
        XCTAssertEqual(m.handle(.tick(at: at(7.5 + DictationMachine.silenceToSend))), [.finishListening])
        XCTAssertEqual(m.phase, .finishing(send: true))
        // Late ticks and transcripts while finishing do nothing.
        XCTAssertEqual(m.handle(.tick(at: at(20))), [])
        XCTAssertEqual(m.handle(.finished("What should I cook tonight?")), [.send("What should I cook tonight?")])
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.transcript, "")
    }

    func testAnEmptyFinalTranscriptFallsBackToTheLiveOne() {
        var m = listening(autoSend: true)
        m.handle(.transcript("  Hello there ", at: at(1)))
        XCTAssertEqual(m.handle(.sendNow), [.finishListening])
        XCTAssertEqual(m.handle(.finished("")), [.send("Hello there")])
    }

    func testSendNowSendsWhatWasHeardAndCancelsWithNothing() {
        var m = listening(autoSend: true)
        XCTAssertEqual(m.handle(.sendNow), [.cancelListening], "nothing heard: a second press stops")
        XCTAssertEqual(m.phase, .idle)

        m = listening(autoSend: false)
        m.handle(.transcript("Remind me", at: at(1)))
        XCTAssertEqual(m.handle(.sendNow), [.finishListening])
        XCTAssertEqual(m.handle(.finished("Remind me.")), [.send("Remind me.")])
    }

    func testSendNowWhileStillStartingWithWords() {
        var m = DictationMachine()
        m.handle(.start(autoSend: true, at: t0))
        m.handle(.transcript("Quick one", at: at(0.5)))
        XCTAssertEqual(m.handle(.sendNow), [.finishListening])
        XCTAssertEqual(m.phase, .finishing(send: true))
    }

    func testCancelDiscards() {
        var m = listening(autoSend: true)
        m.handle(.transcript("Never mind", at: at(1)))
        XCTAssertEqual(m.handle(.cancel), [.cancelListening])
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.transcript, "")
        // A transcript after cancel is ignored.
        XCTAssertEqual(m.handle(.transcript("late", at: at(2))), [])
        XCTAssertEqual(m.transcript, "")
        // Cancel while finishing drops the final transcript too.
        m = listening(autoSend: true)
        m.handle(.transcript("Hi", at: at(1)))
        m.handle(.sendNow)
        XCTAssertEqual(m.handle(.cancel), [.cancelListening])
        XCTAssertEqual(m.handle(.finished("Hi")), [])
    }

    func testWithoutAutoSendSilenceKeepsListeningThenStopsIntoTheDraft() {
        var m = listening(autoSend: false)
        m.handle(.transcript("Draft words", at: at(1)))
        XCTAssertEqual(m.handle(.tick(at: at(1 + DictationMachine.silenceToSend + 1))), [])
        XCTAssertEqual(m.phase, .listening)
        XCTAssertEqual(m.handle(.tick(at: at(1 + DictationMachine.idleTimeout))), [.finishListening])
        XCTAssertEqual(m.phase, .finishing(send: false))
        XCTAssertEqual(m.handle(.finished("Draft words.")), [.keepDraft("Draft words.")])
    }

    func testStopKeepsTheDraft() {
        var m = listening(autoSend: false)
        m.handle(.transcript("Half a thought", at: at(1)))
        XCTAssertEqual(m.handle(.stop), [.finishListening])
        XCTAssertEqual(m.handle(.finished("Half a thought")), [.keepDraft("Half a thought")])
    }

    func testNothingHeardTimesOutAndSendsNothing() {
        var m = listening(autoSend: true)
        XCTAssertEqual(m.handle(.tick(at: at(DictationMachine.idleTimeout - 1))), [])
        XCTAssertEqual(m.handle(.tick(at: at(DictationMachine.idleTimeout))), [.finishListening])
        XCTAssertEqual(m.handle(.finished("")), [])
        XCTAssertEqual(m.phase, .idle)
    }

    func testAFailureKeepsWhatWasHeardAsADraft() {
        var m = listening(autoSend: true)
        XCTAssertEqual(m.handle(.failed("no microphone")), [.cancelListening])
        XCTAssertEqual(m.phase, .failed("no microphone"))
        XCTAssertFalse(m.isActive)
        // It can start again after a failure.
        XCTAssertEqual(m.handle(.start(autoSend: true, at: at(1))), [.startListening])

        m = listening(autoSend: true)
        m.handle(.transcript("Something", at: at(1)))
        XCTAssertEqual(m.handle(.failed("interrupted")), [.cancelListening, .keepDraft("Something")])
    }

    func testStartWhileActiveIsIgnored() {
        var m = listening(autoSend: true)
        XCTAssertEqual(m.handle(.start(autoSend: false, at: at(1))), [])
        XCTAssertTrue(m.autoSend)
        XCTAssertTrue(m.isListening)
    }
}

final class LiveTranscriptTests: XCTestCase {
    func testVolatileSegmentsReplaceEachOtherAndFinalOnesAccumulate() {
        var t = LiveTranscript()
        t.update("What", isFinal: false)
        t.update("What should", isFinal: false)
        XCTAssertEqual(t.text, "What should")
        t.update(" What should I cook tonight?", isFinal: true)
        XCTAssertEqual(t.text, "What should I cook tonight?")
        t.update("Something", isFinal: false)
        XCTAssertEqual(t.text, "What should I cook tonight? Something")
        t.update("Something quick.", isFinal: true)
        XCTAssertEqual(t.text, "What should I cook tonight? Something quick.")
        t.replace(with: "All of it")
        XCTAssertEqual(t.text, "All of it")
        XCTAssertEqual(LiveTranscript.join("Typed text ", " and spoken"), "Typed text and spoken")
        XCTAssertEqual(LiveTranscript.join("", "spoken"), "spoken")
        XCTAssertEqual(LiveTranscript.join("typed", "  "), "typed")
    }
}
