import Foundation

/// `timings.json` (`parley.timings/v1`): when each sentence and word of the
/// shown text is heard. Character offsets are half-open ranges of Unicode
/// scalars in the reply text (the relay indexes Python strings by code point).
public struct Timings: Codable, Hashable, Sendable {
    public struct Sentence: Codable, Hashable, Sendable {
        public var index: Int
        public var charStart: Int
        public var charEnd: Int
        public var startMs: Int
        public var endMs: Int

        public init(index: Int, charStart: Int, charEnd: Int, startMs: Int, endMs: Int) {
            self.index = index
            self.charStart = charStart
            self.charEnd = charEnd
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    public struct Word: Codable, Hashable, Sendable {
        public var index: Int
        public var charStart: Int
        public var charEnd: Int
        public var startMs: Int
        public var endMs: Int
        public var sentence: Int

        public init(index: Int, charStart: Int, charEnd: Int, startMs: Int, endMs: Int, sentence: Int) {
            self.index = index
            self.charStart = charStart
            self.charEnd = charEnd
            self.startMs = startMs
            self.endMs = endMs
            self.sentence = sentence
        }
    }

    public static let format = "parley.timings/v1"

    public var format: String
    public var source: String
    public var durationMs: Int
    public var textLength: Int
    public var sentences: [Sentence]
    public var words: [Word]

    public init(format: String = Timings.format, source: String = "estimated", durationMs: Int, textLength: Int,
                sentences: [Sentence], words: [Word]) {
        self.format = format
        self.source = source
        self.durationMs = durationMs
        self.textLength = textLength
        self.sentences = sentences
        self.words = words
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedFormat(String)
        case outOfRange
    }

    /// Decode and check the timings against the text they describe.
    public static func decode(_ data: Data, for text: String) throws -> Timings {
        let timings = try ParleyJSON.decoder.decode(Timings.self, from: data)
        guard timings.format == Timings.format else { throw DecodeError.unsupportedFormat(timings.format) }
        let length = text.unicodeScalars.count
        if timings.words.contains(where: { $0.charStart < 0 || $0.charEnd > length || $0.charStart >= $0.charEnd }) {
            throw DecodeError.outOfRange
        }
        if timings.sentences.contains(where: { $0.charStart < 0 || $0.charEnd > length || $0.charStart > $0.charEnd }) {
            throw DecodeError.outOfRange
        }
        return timings
    }
}

/// Unicode-scalar offsets into a Swift string.
public enum ScalarText {
    public static func index(_ text: String, offset: Int) -> String.Index {
        let scalars = text.unicodeScalars
        return scalars.index(scalars.startIndex, offsetBy: max(0, min(offset, scalars.count)))
    }

    public static func slice(_ text: String, _ start: Int, _ end: Int) -> String {
        let scalars = text.unicodeScalars
        let a = scalars.index(scalars.startIndex, offsetBy: max(0, min(start, scalars.count)))
        let b = scalars.index(scalars.startIndex, offsetBy: max(0, min(end, scalars.count)))
        return a < b ? String(scalars[a..<b]) : ""
    }
}

/// A piece of the reader's text: one word (`core`) with the punctuation and
/// space after it (`trail`), or text before the first word. The reader lays
/// these out in a flow, so a tap on a word can seek to it, and highlights the
/// core alone.
public struct ReaderToken: Hashable, Sendable, Identifiable {
    public var id: Int
    public var core: String
    public var trail: String
    public var word: Int?
    public var sentence: Int?
    /// True when the token ends a paragraph or a line in the text.
    public var breaksLine: Bool

    public var text: String { core + trail }
}

public enum ReaderLayout {
    /// Split `text` into tokens along its timed words. Every character of the
    /// text is in exactly one token, in order (line breaks become the end of a
    /// line).
    public static func tokens(text: String, timings: Timings?) -> [ReaderToken] {
        let total = text.unicodeScalars.count
        guard let timings, !timings.words.isEmpty else {
            return plainTokens(text)
        }
        var tokens: [ReaderToken] = []
        var cursor = 0
        let words = timings.words.sorted { $0.charStart < $1.charStart }
        if let first = words.first, first.charStart > 0 {
            append(&tokens, core: "", trail: ScalarText.slice(text, 0, first.charStart), word: nil,
                   sentence: first.sentence)
            cursor = first.charStart
        }
        for (i, w) in words.enumerated() {
            let start = max(cursor, w.charStart)
            let coreEnd = max(start, min(w.charEnd, total))
            let end = i + 1 < words.count ? max(coreEnd, words[i + 1].charStart) : total
            append(&tokens, core: ScalarText.slice(text, start, coreEnd), trail: ScalarText.slice(text, coreEnd, end),
                   word: w.index, sentence: w.sentence)
            cursor = end
        }
        return tokens
    }

    private static func append(_ tokens: inout [ReaderToken], core: String, trail: String, word: Int?, sentence: Int?) {
        guard !(core.isEmpty && trail.isEmpty) else { return }
        let breaks = trail.contains("\n") || core.contains("\n")
        var shownCore = core
        var shownTrail = trail
        if breaks {
            shownCore = core.replacingOccurrences(of: "\n", with: " ")
            shownTrail = trail.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) + " "
        }
        tokens.append(ReaderToken(id: tokens.count, core: shownCore, trail: shownTrail, word: word, sentence: sentence,
                                  breaksLine: breaks))
    }

    private static func plainTokens(_ text: String) -> [ReaderToken] {
        var tokens: [ReaderToken] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == " " || ch == "\n" {
                append(&tokens, core: "", trail: current, word: nil, sentence: nil)
                current = ""
            }
        }
        append(&tokens, core: "", trail: current, word: nil, sentence: nil)
        return tokens
    }
}
