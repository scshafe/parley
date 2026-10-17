import XCTest
@testable import ParleyKit

/// A timings.json as the relay writes it (relay/src/parley_relay/timings.py).
let sampleText = "Good morning, friend. The plan is simple."
let sampleTimingsJSON = """
{"format":"parley.timings/v1","source":"estimated","offsets":"unicode-scalars","duration_ms":4000,
 "text_length":41,"turn_id":"t_1","exact_sentences":true,
 "sentences":[{"index":0,"char_start":0,"char_end":21,"start_ms":0,"end_ms":1500},
              {"index":1,"char_start":22,"char_end":41,"start_ms":1500,"end_ms":4000}],
 "words":[{"index":0,"char_start":0,"char_end":4,"start_ms":60,"end_ms":300,"sentence":0},
          {"index":1,"char_start":5,"char_end":12,"start_ms":300,"end_ms":800,"sentence":0},
          {"index":2,"char_start":14,"char_end":20,"start_ms":1000,"end_ms":1300,"sentence":0},
          {"index":3,"char_start":22,"char_end":25,"start_ms":1560,"end_ms":1800,"sentence":1},
          {"index":4,"char_start":26,"char_end":30,"start_ms":1800,"end_ms":2100,"sentence":1},
          {"index":5,"char_start":31,"char_end":33,"start_ms":2100,"end_ms":2300,"sentence":1},
          {"index":6,"char_start":34,"char_end":40,"start_ms":2300,"end_ms":3000,"sentence":1}]}
"""

final class TimingsTests: XCTestCase {
    func testDecodesTheRelaysFormat() throws {
        let t = try Timings.decode(Data(sampleTimingsJSON.utf8), for: sampleText)
        XCTAssertEqual(t.durationMs, 4000)
        XCTAssertEqual(t.sentences.count, 2)
        XCTAssertEqual(t.words.count, 7)
        XCTAssertEqual(ScalarText.slice(sampleText, t.words[1].charStart, t.words[1].charEnd), "morning")
        XCTAssertEqual(ScalarText.slice(sampleText, t.sentences[1].charStart, t.sentences[1].charEnd),
                       "The plan is simple.")
    }

    func testRejectsAnotherFormatOrOutOfRangeOffsets() {
        let other = sampleTimingsJSON.replacingOccurrences(of: "parley.timings/v1", with: "parley.timings/v9")
        XCTAssertThrowsError(try Timings.decode(Data(other.utf8), for: sampleText))
        XCTAssertThrowsError(try Timings.decode(Data(sampleTimingsJSON.utf8), for: "short"))
    }

    func testScalarOffsetsMatchPythonCodePoints() {
        // "é" as one scalar, an emoji outside the BMP as one scalar (Python counts both as 1).
        let text = "Café 🎉 time"
        XCTAssertEqual(ScalarText.slice(text, 0, 4), "Café")
        XCTAssertEqual(ScalarText.slice(text, 5, 6), "🎉")
        XCTAssertEqual(ScalarText.slice(text, 7, 11), "time")
        XCTAssertEqual(ScalarText.slice(text, 9, 99), "me")
        XCTAssertEqual(ScalarText.slice(text, 5, 2), "")
    }

    func testReaderTokensCoverTheTextAndCarryWords() throws {
        let t = try Timings.decode(Data(sampleTimingsJSON.utf8), for: sampleText)
        let tokens = ReaderLayout.tokens(text: sampleText, timings: t)
        XCTAssertEqual(tokens.map(\.text).joined(), sampleText)
        XCTAssertEqual(tokens.compactMap(\.word), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(tokens[1].text, "morning, ")
        XCTAssertEqual(tokens[1].core, "morning")
        XCTAssertEqual(tokens[1].trail, ", ")
        XCTAssertEqual(tokens.last?.text, "simple.")
        XCTAssertEqual(tokens[3].sentence, 1)
    }

    func testReaderTokensWithoutTimingsAndWithLineBreaks() throws {
        let text = "Plan:\n\nbuy milk.\ncall Sam."
        let plain = ReaderLayout.tokens(text: text, timings: nil)
        XCTAssertTrue(plain.allSatisfy { $0.word == nil })
        XCTAssertEqual(plain.filter(\.breaksLine).count, 3)
        let timings = Timings(durationMs: 1000, textLength: text.unicodeScalars.count,
                              sentences: [.init(index: 0, charStart: 0, charEnd: 26, startMs: 0, endMs: 1000)],
                              words: [.init(index: 0, charStart: 0, charEnd: 4, startMs: 0, endMs: 100, sentence: 0),
                                      .init(index: 1, charStart: 7, charEnd: 10, startMs: 100, endMs: 200, sentence: 0)])
        let tokens = ReaderLayout.tokens(text: text, timings: timings)
        XCTAssertEqual(tokens.first?.text, "Plan: ")
        XCTAssertEqual(tokens.first?.breaksLine, true)
        XCTAssertEqual(tokens.count, 2)
    }
}

final class HighlightCursorTests: XCTestCase {
    var cursor: HighlightCursor!

    override func setUpWithError() throws {
        cursor = HighlightCursor(timings: try Timings.decode(Data(sampleTimingsJSON.utf8), for: sampleText))
    }

    func testNothingBeforeTheFirstWord() {
        XCTAssertEqual(cursor.position(at: 0), .init(word: nil, sentence: 0))
        XCTAssertEqual(cursor.position(at: -10), .init(word: nil, sentence: nil))
    }

    func testTheWordAndSentenceAtATime() {
        XCTAssertEqual(cursor.position(at: 60), .init(word: 0, sentence: 0))
        XCTAssertEqual(cursor.position(at: 799), .init(word: 1, sentence: 0))
        // In the pause after "morning," the highlight stays on it.
        XCTAssertEqual(cursor.position(at: 900), .init(word: 1, sentence: 0))
        XCTAssertEqual(cursor.position(at: 1500), .init(word: 2, sentence: 1))
        XCTAssertEqual(cursor.position(at: 1600), .init(word: 3, sentence: 1))
        XCTAssertEqual(cursor.position(at: 2999), .init(word: 6, sentence: 1))
    }

    func testAfterTheEndTheLastWordStays() {
        XCTAssertEqual(cursor.position(at: 10_000), .init(word: 6, sentence: 1))
    }

    func testCursorAdvancesMonotonically() {
        var last = -1
        for ms in stride(from: 0, through: 4000, by: 10) {
            let w = cursor.position(at: ms).word ?? -1
            XCTAssertGreaterThanOrEqual(w, last)
            last = w
        }
        XCTAssertEqual(last, 6)
    }

    func testHeardTimeAllowsForOutputLatency() {
        // AirPods: 200 ms of latency puts the ear 200 ms behind the player; at
        // 1.5x, 300 ms of audio passes in those 200 ms.
        XCTAssertEqual(HighlightCursor.latencyMs(outputLatency: 0.2, rate: 1), 200)
        XCTAssertEqual(HighlightCursor.latencyMs(outputLatency: 0.2, rate: 1.5), 300)
        XCTAssertEqual(HighlightCursor.heardMs(playerMs: 1800, latencyMs: 200), 1600)
        XCTAssertEqual(HighlightCursor.heardMs(playerMs: 100, latencyMs: 200), 0)
        // So "The" (1560 ms) is still unlit at a player time of 1700 over Bluetooth.
        XCTAssertEqual(cursor.position(at: HighlightCursor.heardMs(playerMs: 1700, latencyMs: 200)).word, 2)
        // After a seek to "The", it lights at once, and the clock takes over
        // once the sound has caught up.
        XCTAssertEqual(HighlightCursor.heardMs(playerMs: 1560, latencyMs: 200, floorMs: 1560), 1560)
        XCTAssertEqual(HighlightCursor.heardMs(playerMs: 2100, latencyMs: 200, floorMs: 1560), 1900)
        XCTAssertEqual(HighlightCursor.heardMs(playerMs: 1800, latencyMs: 0, floorMs: 1560), 1800)
    }

    func testSeekAndHitTesting() {
        XCTAssertEqual(cursor.seekTime(forWord: 3), 1560)
        XCTAssertNil(cursor.seekTime(forWord: 99))
        XCTAssertEqual(cursor.word(atCharacter: 7), 1)
        XCTAssertNil(cursor.word(atCharacter: 13))
    }

    func testEmptyTimings() {
        let c = HighlightCursor(timings: Timings(durationMs: 0, textLength: 0, sentences: [], words: []))
        XCTAssertEqual(c.position(at: 100), .init(word: nil, sentence: nil))
    }
}
