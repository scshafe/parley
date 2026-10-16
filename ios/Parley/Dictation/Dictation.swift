import Foundation
import Observation
import os
import ParleyKit

private let log = Logger(subsystem: "com.scshafe.parley", category: "dictation")

/// In-app dictation: the Action Button's new conversation (auto-send) and the
/// composer's mic. `DictationMachine` (ParleyKit) decides when to send, stop
/// or give up; this object runs it: permissions, the audio session, a speech
/// engine (`SpeechEngines.swift`) and a clock tick.
///
/// One dictation at a time. Its owner (the conversation on screen) gets the
/// text through `onSend` and `onKeepDraft`.
@Observable
@MainActor
final class Dictation {
    /// How often the machine looks at the clock (silence, time-outs).
    static let tickInterval: Duration = .milliseconds(250)

    private(set) var machine = DictationMachine()
    /// "Getting speech recognition ready…" while a model downloads.
    private(set) var status: String?
    /// The conversation view that started it, so another view leaves it alone.
    private(set) var ownerID: UUID?

    var transcript: String { machine.transcript }
    var isActive: Bool { machine.isActive }
    var isListening: Bool { machine.isListening }
    var autoSend: Bool { machine.autoSend }

    @ObservationIgnored private weak var player: PlayerController?
    @ObservationIgnored private var engine: SpeechEngine?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var onSend: ((String) -> Void)?
    @ObservationIgnored private var onKeepDraft: ((String) -> Void)?
    @ObservationIgnored private var onFailure: ((String) -> Void)?

    init(player: PlayerController) {
        self.player = player
    }

    // MARK: Commands

    /// Start listening for `owner`. Reply playback stops first.
    func start(autoSend: Bool, owner: UUID, onSend: @escaping (String) -> Void,
               onKeepDraft: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        guard !machine.isActive else { return }
        ownerID = owner
        self.onSend = onSend
        self.onKeepDraft = onKeepDraft
        self.onFailure = onFailure
        perform(machine.handle(.start(autoSend: autoSend, at: Date())))
    }

    /// The Send button, or the Action Button pressed again: send what was
    /// heard now (nothing heard: stop).
    func sendNow() { perform(machine.handle(.sendNow)) }

    /// Stop listening and keep the words in the draft.
    func stop() { perform(machine.handle(.stop)) }

    /// Stop and throw the words away.
    func cancel() { perform(machine.handle(.cancel)) }

    /// The owner went away: drop a dictation that belongs to it.
    func ownerDisappeared(_ owner: UUID) {
        guard ownerID == owner, machine.isActive else { return }
        cancel()
    }

    // MARK: Effects

    private func perform(_ effects: [DictationMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startListening:
                generation += 1
                let g = generation
                startTask = Task { await self.begin(generation: g) }
            case .finishListening:
                stopTicker()
                let g = generation
                let starting = startTask
                Task {
                    await starting?.value
                    let text = await self.engine?.finish() ?? ""
                    guard g == self.generation else { return }
                    self.tearDown()
                    self.perform(self.machine.handle(.finished(text)))
                }
            case .cancelListening:
                generation += 1
                startTask?.cancel()
                engine?.cancel()
                tearDown()
            case .send(let text):
                onSend?(text)
            case .keepDraft(let text):
                onKeepDraft?(text)
            }
        }
    }

    private func begin(generation g: Int) async {
        player?.stop()
        let engine: SpeechEngine
        do {
            engine = try await makeEngine()
            guard g == generation else { return }
            if engine.usesMicrophone {
                try DictationAudioSession.begin()
                sessionActive = true
            }
            self.engine = engine
            try await engine.start(onText: { [weak self] text in
                guard let self, g == self.generation else { return }
                self.perform(self.machine.handle(.transcript(text, at: Date())))
            }, onStatus: { [weak self] status in
                guard let self, g == self.generation else { return }
                self.status = status
            })
        } catch {
            guard g == generation else { return }
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("dictation failed to start: \(why, privacy: .public)")
            self.engine?.cancel()
            tearDown()
            perform(machine.handle(.failed(why)))
            onFailure?(why)
            return
        }
        guard g == generation else {
            engine.cancel()
            return
        }
        status = nil
        perform(machine.handle(.started(at: Date())))
        startTicker(generation: g)
    }

    /// Permission, then SpeechAnalyzer if it has a model for this language,
    /// else SFSpeechRecognizer.
    private func makeEngine() async throws -> SpeechEngine {
        #if DEBUG && targetEnvironment(simulator)
        if let script = UITestSeam.current?.dictationScript { return ScriptedEngine(script: script) }
        #endif
        try await DictationPermission.request()
        if let analyzer = await AnalyzerEngine.make(locale: Locale.current) {
            return FallbackEngine(primary: analyzer, fallback: { RecognizerEngine() })
        }
        return RecognizerEngine()
    }

    private func startTicker(generation g: Int) {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Dictation.tickInterval)
                guard let self, g == self.generation, !Task.isCancelled else { return }
                self.perform(self.machine.handle(.tick(at: Date())))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tearDown() {
        stopTicker()
        engine = nil
        status = nil
        if sessionActive {
            sessionActive = false
            DictationAudioSession.end()
        }
    }
}

/// SpeechAnalyzer first; if it cannot start (its model will not download,
/// say), SFSpeechRecognizer instead.
@MainActor
final class FallbackEngine: SpeechEngine {
    private let primary: SpeechEngine
    private let makeFallback: () -> SpeechEngine
    private var active: SpeechEngine?

    init(primary: SpeechEngine, fallback: @escaping () -> SpeechEngine) {
        self.primary = primary
        makeFallback = fallback
    }

    var name: String { active?.name ?? primary.name }
    let usesMicrophone = true

    func start(onText: @escaping @MainActor (String) -> Void,
               onStatus: @escaping @MainActor (String?) -> Void) async throws {
        do {
            try await primary.start(onText: onText, onStatus: onStatus)
            active = primary
        } catch DictationError.noMicrophone {
            throw DictationError.noMicrophone
        } catch {
            log.error("\(self.primary.name, privacy: .public) could not start (\(error.localizedDescription, privacy: .public)); falling back")
            primary.cancel()
            onStatus(nil)
            let fallback = makeFallback()
            try await fallback.start(onText: onText, onStatus: onStatus)
            active = fallback
        }
    }

    func finish() async -> String { await active?.finish() ?? "" }

    func cancel() {
        (active ?? primary).cancel()
    }
}
