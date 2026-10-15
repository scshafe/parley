import Foundation

/// Which word and sentence are heard at a time on the audio clock.
///
/// A word is current from its start until the next word starts, so the
/// highlight rests on a word through the pause after it instead of flickering
/// off. Before the first word nothing is highlighted; after the audio's end the
/// last word stays.
public struct HighlightCursor: Sendable {
    public struct Position: Equatable, Sendable {
        public var word: Int?
        public var sentence: Int?

        public init(word: Int?, sentence: Int?) {
            self.word = word
            self.sentence = sentence
        }
    }

    public let timings: Timings
    private let starts: [Int]
    private let order: [Int]

    public init(timings: Timings) {
        self.timings = timings
        let sorted = timings.words.enumerated().sorted { $0.element.startMs < $1.element.startMs }
        self.order = sorted.map { $0.offset }
        self.starts = sorted.map { $0.element.startMs }
    }

    /// The position at `ms` milliseconds into the reply's audio.
    public func position(at ms: Int) -> Position {
        let sentence = sentenceIndex(at: ms)
        guard !starts.isEmpty, ms >= starts[0] else {
            return Position(word: nil, sentence: sentence)
        }
        // The last word whose start is at or before ms.
        var lo = 0
        var hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= ms { lo = mid } else { hi = mid - 1 }
        }
        let word = timings.words[order[lo]]
        return Position(word: word.index, sentence: sentence ?? word.sentence)
    }

    private func sentenceIndex(at ms: Int) -> Int? {
        let sentences = timings.sentences
        guard !sentences.isEmpty else { return nil }
        var lo = 0
        var hi = sentences.count - 1
        guard ms >= sentences[0].startMs else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sentences[mid].startMs <= ms { lo = mid } else { hi = mid - 1 }
        }
        let s = sentences[lo]
        if ms < s.endMs { return s.index }
        // Past the end of the audio, the last sentence stays tinted.
        if lo == sentences.count - 1 && ms >= s.endMs { return s.index }
        return nil
    }

    /// Where a tap on a word seeks to: its start.
    public func seekTime(forWord index: Int) -> Int? {
        timings.words.first { $0.index == index }?.startMs
    }

    /// The word whose character range holds `offset` (a Unicode scalar offset).
    public func word(atCharacter offset: Int) -> Int? {
        timings.words.first { $0.charStart <= offset && offset < $0.charEnd }?.index
    }
}
