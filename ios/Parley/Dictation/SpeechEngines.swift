import AVFoundation
import Foundation
import os
import ParleyKit
import Speech

private let log = Logger(subsystem: "com.scshafe.parley", category: "dictation")

/// Speech to text from the microphone, for dictation. `start` returns once
/// the microphone runs; `onText` gets the whole transcript so far, each time
/// it changes. `finish` stops the microphone and returns the final text.
@MainActor
protocol SpeechEngine: AnyObject {
    /// What recognizes the speech, for the log and the README's claims.
    var name: String { get }
    /// Whether it records (and so needs the audio session).
    var usesMicrophone: Bool { get }
    func start(onText: @escaping @MainActor (String) -> Void,
               onStatus: @escaping @MainActor (String?) -> Void) async throws
    func finish() async -> String
    func cancel()
}

enum DictationError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case speechRestricted
    case noMicrophone
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Parley may not use the microphone. Turn it on in Settings → Apps → Parley → Microphone."
        case .speechDenied:
            return "Parley may not use speech recognition. Turn it on in Settings → Apps → Parley → Speech Recognition."
        case .speechRestricted:
            return "Speech recognition is restricted on this iPhone (Screen Time or a profile)."
        case .noMicrophone:
            return "No microphone is available."
        case .unavailable(let why):
            return "Dictation is not available: \(why)"
        }
    }
}

/// Microphone and speech recognition permission: the system asks the first
/// time, then answers from the person's choice in Settings.
enum DictationPermission {
    static func request() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphoneDenied }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        switch status {
        case .authorized: return
        case .denied: throw DictationError.speechDenied
        case .restricted: throw DictationError.speechRestricted
        case .notDetermined: throw DictationError.speechDenied
        @unknown default: throw DictationError.speechDenied
        }
    }
}

/// The audio session around listening: record (other audio ducked), then
/// handed back. The reader-player sets its own playback category whenever it
/// loads a reply, so playback afterwards is unaffected.
enum DictationAudioSession {
    static func begin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    static func end() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.error("audio session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Converts the microphone's buffers to the analyzer's format, on the audio
/// thread.
private final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    let format: AVAudioFormat

    init(from input: AVAudioFormat, to format: AVAudioFormat) {
        self.format = format
        converter = input == format ? nil : AVAudioConverter(from: input, to: format)
        converter?.primeMethod = .none
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

/// iOS 26's SpeechAnalyzer, on device: `SpeechTranscriber` where the
/// hardware supports it, else `DictationTranscriber` (the keyboard
/// dictation's model). The locale's model is downloaded once if needed.
@MainActor
final class AnalyzerEngine: SpeechEngine {
    private enum Module {
        case transcriber(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .transcriber(let m): return m
            case .dictation(let m): return m
            }
        }
    }

    private let module: Module
    private let audio = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var transcript = LiveTranscript()
    private var tapInstalled = false

    let name: String
    let usesMicrophone = true

    private init(module: Module, name: String) {
        self.module = module
        self.name = name
    }

    /// An engine for `locale`, or nil when neither module supports it here
    /// (the simulator, for one, has no SpeechTranscriber).
    static func make(locale: Locale) async -> AnalyzerEngine? {
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let m = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                      reportingOptions: [.volatileResults], attributeOptions: [])
            return AnalyzerEngine(module: .transcriber(m), name: "SpeechTranscriber (\(supported.identifier), on device)")
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let m = DictationTranscriber(locale: supported, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults], attributeOptions: [])
            return AnalyzerEngine(module: .dictation(m), name: "DictationTranscriber (\(supported.identifier), on device)")
        }
        return nil
    }

    func start(onText: @escaping @MainActor (String) -> Void,
               onStatus: @escaping @MainActor (String?) -> Void) async throws {
        let modules = [module.module]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            onStatus("Getting speech recognition ready…")
            try await request.downloadAndInstall()
            onStatus(nil)
        }
        let natural = audio.inputNode.outputFormat(forBus: 0)
        guard natural.channelCount > 0, natural.sampleRate > 0 else { throw DictationError.noMicrophone }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: natural)
        else { throw DictationError.unavailable("no audio format for the speech model") }

        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)

        switch module {
        case .transcriber(let m):
            resultsTask = consume(m.results, text: { String($0.text.characters) }, isFinal: { $0.isFinal }, onText: onText)
        case .dictation(let m):
            resultsTask = consume(m.results, text: { String($0.text.characters) }, isFinal: { $0.isFinal }, onText: onText)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        try await analyzer.start(inputSequence: stream)

        let converter = BufferConverter(from: natural, to: format)
        audio.inputNode.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            if let converted = converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        tapInstalled = true
        audio.prepare()
        try audio.start()
        log.info("listening with \(self.name, privacy: .public)")
    }

    private func consume<S: AsyncSequence>(_ results: S, text: @escaping @Sendable (S.Element) -> String,
                                           isFinal: @escaping @Sendable (S.Element) -> Bool,
                                           onText: @escaping @MainActor (String) -> Void) -> Task<Void, Never>
        where S: Sendable, S.Element: Sendable {
        Task { @MainActor [weak self] in
            do {
                for try await result in results {
                    guard let self else { return }
                    self.transcript.update(text(result), isFinal: isFinal(result))
                    onText(self.transcript.text)
                }
            } catch {
                log.error("results ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stopAudio() {
        audio.stop()
        if tapInstalled {
            audio.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        input?.finish()
        input = nil
    }

    func finish() async -> String {
        stopAudio()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            log.error("finalize failed: \(error.localizedDescription, privacy: .public)")
        }
        await waitForResults(resultsTask, upTo: .seconds(3))
        analyzer = nil
        return transcript.text
    }

    func cancel() {
        stopAudio()
        resultsTask?.cancel()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }
}

/// The older SFSpeechRecognizer, on device when this iPhone supports it for
/// the locale (otherwise Apple's servers): where SpeechAnalyzer has no model,
/// such as the simulator.
@MainActor
final class RecognizerEngine: SpeechEngine {
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var text = ""
    private var finalTask: Task<Void, Never>?
    private var finalReceived: CheckedContinuation<Void, Never>?
    private var isFinal = false
    private var tapInstalled = false
    private(set) var name = "SFSpeechRecognizer"
    let usesMicrophone = true

    func start(onText: @escaping @MainActor (String) -> Void,
               onStatus: @escaping @MainActor (String?) -> Void) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw DictationError.unavailable("speech recognition is not available for this language right now")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            name = "SFSpeechRecognizer (\(recognizer.locale.identifier), on device)"
        } else {
            name = "SFSpeechRecognizer (\(recognizer.locale.identifier), server)"
        }
        self.request = request
        let natural = audio.inputNode.outputFormat(forBus: 0)
        guard natural.channelCount > 0, natural.sampleRate > 0 else { throw DictationError.noMicrophone }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text, !self.isFinal {
                    self.text = text
                    onText(text)
                }
                if done { self.markFinal() }
            }
        }
        audio.inputNode.installTap(onBus: 0, bufferSize: 1024, format: natural) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        audio.prepare()
        try audio.start()
        log.info("listening with \(self.name, privacy: .public)")
    }

    private func markFinal() {
        isFinal = true
        finalReceived?.resume()
        finalReceived = nil
    }

    private func stopAudio() {
        audio.stop()
        if tapInstalled {
            audio.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    func finish() async -> String {
        stopAudio()
        request?.endAudio()
        if !isFinal {
            let wait = Task { @MainActor in
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    if self.isFinal { done.resume() } else { self.finalReceived = done }
                }
            }
            await waitForResults(wait, upTo: .seconds(3))
            if !isFinal { markFinal() }
        }
        task = nil
        request = nil
        return text
    }

    func cancel() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        markFinal()
    }
}

/// Wait for `task` to end, but no longer than `limit`.
@MainActor
private func waitForResults(_ task: Task<Void, Never>?, upTo limit: Duration) async {
    guard let task else { return }
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await task.value }
        group.addTask { try? await Task.sleep(for: limit) }
        await group.next()
        group.cancelAll()
    }
}

#if DEBUG && targetEnvironment(simulator)
/// The UI tests' stand-in (`PARLEY_UI_TEST_DICTATION`): "hears" the given
/// words one at a time, then nothing, as a person who stops talking.
@MainActor
final class ScriptedEngine: SpeechEngine {
    private let words: [String]
    private var feeding: Task<Void, Never>?
    private var heard = ""
    let name = "scripted (UI tests)"
    let usesMicrophone = false

    init(script: String) {
        words = script.split(separator: " ").map(String.init)
    }

    func start(onText: @escaping @MainActor (String) -> Void,
               onStatus: @escaping @MainActor (String?) -> Void) async throws {
        feeding = Task { @MainActor [weak self] in
            guard let self else { return }
            for word in self.words {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                self.heard = LiveTranscript.join(self.heard, word)
                onText(self.heard)
            }
        }
    }

    func finish() async -> String {
        feeding?.cancel()
        return heard
    }

    func cancel() {
        feeding?.cancel()
        heard = ""
    }
}
#endif
