import Foundation

/// When dictation sends, stops or gives up, kept free of Speech and
/// AVFoundation so it is tested on its own. The app's dictation feeds it the
/// live transcript and a clock tick, and performs the effects.
///
/// - **Auto-send** (the Action Button's new conversation): once some words
///   were heard, `silenceToSend` without a new word sends the message.
/// - **Without auto-send** (the composer's mic): the words go into the draft;
///   the person sends it, or listening stops after `idleTimeout` without a
///   new word.
/// - **Send now** (the Send button, or the Action Button pressed again while
///   listening) finishes and sends what was heard; with nothing heard it
///   cancels.
/// - **Cancel** discards what was heard.
/// - Nothing heard for `idleTimeout` after listening started stops listening
///   and sends nothing.
public struct DictationMachine: Equatable, Sendable {
    /// Silence, after some words, that sends an auto-send message.
    public static let silenceToSend: TimeInterval = 2.0
    /// Listening stops after this long without a new word (or without any).
    public static let idleTimeout: TimeInterval = 20.0

    public enum Phase: Equatable, Sendable {
        case idle
        /// Asking for permission, loading the speech model, starting the microphone.
        case starting
        case listening
        /// The microphone is off; waiting for the final transcript.
        case finishing(send: Bool)
        case failed(String)
    }

    public enum Event: Equatable, Sendable {
        case start(autoSend: Bool, at: Date)
        case started(at: Date)
        case transcript(String, at: Date)
        case tick(at: Date)
        case sendNow
        case stop
        case cancel
        /// The engine is done; `text` is the final transcript.
        case finished(String)
        case failed(String)
    }

    public enum Effect: Equatable, Sendable {
        case startListening
        /// Stop the microphone and get the final transcript (then `.finished`).
        case finishListening
        /// Stop at once and drop the transcript.
        case cancelListening
        case send(String)
        /// Leave this text in the draft.
        case keepDraft(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var transcript = ""
    public private(set) var autoSend = false
    private var startedAt: Date?
    private var lastWordAt: Date?

    public init() {}

    public var isActive: Bool {
        switch phase {
        case .starting, .listening, .finishing: return true
        case .idle, .failed: return false
        }
    }

    public var isListening: Bool { phase == .starting || phase == .listening }

    private var heardSomething: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.idle, .start(let auto, let at)), (.failed, .start(let auto, let at)):
            phase = .starting
            autoSend = auto
            transcript = ""
            startedAt = at
            lastWordAt = nil
            return [.startListening]

        case (.starting, .started(let at)):
            phase = .listening
            startedAt = at
            return []

        case (.starting, .transcript(let text, let at)), (.listening, .transcript(let text, let at)):
            guard text != transcript else { return [] }
            transcript = text
            if heardSomething { lastWordAt = at }
            return []

        case (.listening, .tick(let at)):
            if autoSend, heardSomething, let last = lastWordAt, at.timeIntervalSince(last) >= Self.silenceToSend {
                phase = .finishing(send: true)
                return [.finishListening]
            }
            let since = lastWordAt ?? startedAt ?? at
            if at.timeIntervalSince(since) >= Self.idleTimeout {
                phase = .finishing(send: false)
                return [.finishListening]
            }
            return []

        case (.starting, .sendNow), (.listening, .sendNow):
            guard heardSomething else { return cancel() }
            phase = .finishing(send: true)
            return [.finishListening]

        case (.starting, .stop), (.listening, .stop):
            phase = .finishing(send: false)
            return [.finishListening]

        case (.starting, .cancel), (.listening, .cancel), (.finishing, .cancel):
            return cancel()

        case (.finishing(let send), .finished(let final)):
            let text = Self.pick(final: final, live: transcript)
            phase = .idle
            transcript = ""
            guard !text.isEmpty else { return [] }
            return [send ? .send(text) : .keepDraft(text)]

        case (.starting, .failed(let why)), (.listening, .failed(let why)), (.finishing, .failed(let why)):
            let kept = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed(why)
            transcript = ""
            // What was heard stays in the draft; nothing is sent.
            return kept.isEmpty ? [.cancelListening] : [.cancelListening, .keepDraft(kept)]

        default:
            return []
        }
    }

    private mutating func cancel() -> [Effect] {
        phase = .idle
        transcript = ""
        return [.cancelListening]
    }

    /// The final transcript, or the live one when the engine gave none.
    static func pick(final: String, live: String) -> String {
        let f = final.trimmingCharacters(in: .whitespacesAndNewlines)
        return f.isEmpty ? live.trimmingCharacters(in: .whitespacesAndNewlines) : f
    }
}

/// The transcript as a speech engine reports it: finished segments, plus the
/// segment still being heard (volatile results replace each other).
public struct LiveTranscript: Equatable, Sendable {
    public private(set) var finalized = ""
    public private(set) var volatile = ""

    public init() {}

    public mutating func update(_ segment: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, segment)
            volatile = ""
        } else {
            volatile = segment
        }
    }

    /// Replace everything (an engine that reports the whole text each time).
    public mutating func replace(with text: String) {
        finalized = ""
        volatile = text
    }

    public var text: String { Self.join(finalized, volatile) }

    /// Two pieces of text with one space between them, either may be empty.
    public static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
