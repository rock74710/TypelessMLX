import Foundation
import Speech
import AVFoundation

/// Serves two purposes:
/// 1. **Live preview**: streams partial SFSpeechRecognizer results to RecordingOverlay
///    during any recording session (Breeze / Qwen3 / macOS model).
/// 2. **Standalone model**: final transcription when user picks "macOS 內建" ASR.
class SpeechStreamer {
    static let shared = SpeechStreamer()

    private var recognizer: SFSpeechRecognizer?
    private var streamRequest: SFSpeechAudioBufferRecognitionRequest?
    private var streamGeneration = UUID()
    private var streamTask: SFSpeechRecognitionTask?
    private let lock = NSLock()

    // Final transcription requests are serialized. A new key-up request
    // cancels the previous backend task and completes its callback with a
    // cancellation error, so a late result can never be delivered to the new
    // request.
    private var transcriptionGeneration = 0
    private var activeTranscriptionGate: CompletionGate?
    private var activeLegacyTask: SFSpeechRecognitionTask?
    private var activeModernTask: Task<Void, Never>?

    /// Called on the main thread with the latest partial / final text.
    var liveTextHandler: ((String) -> Void)?

    private(set) var isAuthorized = false

    private init() {}

    private final class CompletionGate {
        private let lock = NSLock()
        private var didComplete = false
        private let completion: (Result<String, Error>) -> Void

        init(completion: @escaping (Result<String, Error>) -> Void) {
            self.completion = completion
        }

        func complete(_ result: Result<String, Error>) {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()

            DispatchQueue.main.async { [completion] in
                completion(result)
            }
        }
    }

    private struct TranscriptionCancelledError: LocalizedError {
        var errorDescription: String? { "語音辨識請求已取消" }
    }

    // MARK: - Authorization

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    // MARK: - Live streaming (overlay preview)

    func startStreaming(language: String?) {
        lock.lock()
        cancelStreamingLocked()
        let generation = streamGeneration
        lock.unlock()

        let locale = Self.locale(for: language)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            logWarn("SpeechStreamer", "Not available for \(locale.identifier)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        lock.lock()
        recognizer = rec
        streamRequest = request
        lock.unlock()

        let task = rec.recognitionTask(with: request) { [weak self] result, _ in
            guard let self = self, let result = result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async {
                self.lock.lock()
                let current = self.streamGeneration == generation
                self.lock.unlock()
                if current { self.liveTextHandler?(text) }
            }
        }

        lock.lock()
        streamTask = task
        lock.unlock()

        logInfo("SpeechStreamer", "Live streaming started (\(locale.identifier))")
    }

    /// Forward each AVAudioPCMBuffer from the recording tap.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let req = streamRequest
        lock.unlock()
        req?.append(buffer)
    }

    /// Signal end-of-audio so SFSpeechRecognizer can flush its final result.
    func stopStreaming() {
        lock.lock()
        let req = streamRequest
        lock.unlock()
        req?.endAudio()
        logInfo("SpeechStreamer", "Streaming ended (flushing)")
    }

    /// Cancel without waiting for a final result (e.g. recording too short).
    func cancelStreaming() {
        lock.lock()
        cancelStreamingLocked()
        lock.unlock()
        liveTextHandler = nil
    }

    private func cancelStreamingLocked() {
        streamGeneration = UUID()
        streamTask?.cancel()
        streamTask = nil
        streamRequest = nil
        recognizer = nil
    }

    // MARK: - Standalone macOS ASR (final result)

    /// Existing entry point retained for callers that do not provide a
    /// contextual dictionary.
    func transcribe(audioURL: URL, language: String?,
                    completion: @escaping (Result<String, Error>) -> Void) {
        transcribe(audioURL: audioURL, language: language,
                   contextualStrings: [], completion: completion)
    }

    /// Final file transcription. On macOS 26+, the modern SpeechAnalyzer path
    /// is attempted first; every modern failure (including an empty result)
    /// falls back exactly once to the existing SFSpeechRecognizer path.
    func transcribe(audioURL: URL, language: String?,
                    contextualStrings: [String] = [],
                    completion: @escaping (Result<String, Error>) -> Void) {
        let locale = Self.locale(for: language)
        let gate = CompletionGate(completion: completion)

        lock.lock()
        transcriptionGeneration &+= 1
        let requestID = transcriptionGeneration
        let previousGate = activeTranscriptionGate
        let previousLegacyTask = activeLegacyTask
        let previousModernTask = activeModernTask
        activeTranscriptionGate = gate
        activeLegacyTask = nil
        activeModernTask = nil
        lock.unlock()

        previousLegacyTask?.cancel()
        previousModernTask?.cancel()
        if previousGate != nil {
            logWarn("SpeechStreamer", "Cancelled superseded final transcription request")
            previousGate?.complete(.failure(TranscriptionCancelledError()))
        }

        let requestStartedAt = Date()

        if #available(macOS 26, *) {
            logInfo("SpeechStreamer", "backend=modern requested locale=\(locale.identifier)")
            let modernTask = Task { [weak self] in
                guard let self = self else { return }

                do {
                    try Task.checkCancellation()
                    let text = try await ModernSpeechTranscriber.shared.transcribe(
                        audioURL: audioURL,
                        locale: locale,
                        contextualStrings: contextualStrings
                    )
                    try Task.checkCancellation()

                    guard self.isCurrentTranscription(requestID, gate: gate) else { return }
                    self.finishSuccess(
                        text,
                        requestID: requestID,
                        gate: gate,
                        locale: locale,
                        backend: "modern",
                        startedAt: requestStartedAt
                    )
                } catch is CancellationError {
                    // A superseding request has already completed this gate.
                } catch {
                    guard self.isCurrentTranscription(requestID, gate: gate) else { return }
                    logWarn("SpeechStreamer", "backend=modern failed locale=\(locale.identifier), fallback=legacy reason=\(error.localizedDescription)")
                    self.startLegacyTranscription(
                        audioURL: audioURL,
                        locale: locale,
                        contextualStrings: contextualStrings,
                        requestID: requestID,
                        gate: gate,
                        startedAt: requestStartedAt,
                        fallbackReason: error.localizedDescription
                    )
                }
            }

            lock.lock()
            if transcriptionGeneration == requestID, activeTranscriptionGate === gate {
                activeModernTask = modernTask
            } else {
                modernTask.cancel()
            }
            lock.unlock()
        } else {
            logInfo("SpeechStreamer", "backend=legacy locale=\(locale.identifier) reason=macOS<26")
            startLegacyTranscription(
                audioURL: audioURL,
                locale: locale,
                contextualStrings: contextualStrings,
                requestID: requestID,
                gate: gate,
                startedAt: requestStartedAt,
                fallbackReason: "macOS 26 Speech API unavailable"
            )
        }
    }

    private func startLegacyTranscription(
        audioURL: URL,
        locale: Locale,
        contextualStrings: [String],
        requestID: Int,
        gate: CompletionGate,
        startedAt: Date,
        fallbackReason: String?
    ) {
        guard isCurrentTranscription(requestID, gate: gate) else { return }

        if let fallbackReason {
            logInfo("SpeechStreamer", "backend=legacy locale=\(locale.identifier) fallback reason=\(fallbackReason)")
        } else {
            logInfo("SpeechStreamer", "backend=legacy locale=\(locale.identifier)")
        }

        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            let err = NSError(domain: "SpeechStreamer", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "macOS 語音辨識不可用（\(locale.identifier)）"])
            completeTranscription(
                .failure(err),
                requestID: requestID,
                gate: gate,
                locale: locale,
                backend: "legacy",
                startedAt: startedAt
            )
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.contextualStrings = contextualStrings

        let task = rec.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            guard self.isCurrentTranscription(requestID, gate: gate) else { return }

            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                self.finishSuccess(
                    text,
                    requestID: requestID,
                    gate: gate,
                    locale: locale,
                    backend: "legacy",
                    startedAt: startedAt
                )
            } else if let error = error {
                logWarn("SpeechStreamer", "backend=legacy failed locale=\(locale.identifier) reason=\(error.localizedDescription)")
                self.completeTranscription(
                    .failure(error),
                    requestID: requestID,
                    gate: gate,
                    locale: locale,
                    backend: "legacy",
                    startedAt: startedAt
                )
            }
        }

        lock.lock()
        if transcriptionGeneration == requestID, activeTranscriptionGate === gate {
            activeLegacyTask = task
        } else {
            task.cancel()
        }
        lock.unlock()
    }

    private func finishSuccess(
        _ text: String,
        requestID: Int,
        gate: CompletionGate,
        locale: Locale,
        backend: String,
        startedAt: Date
    ) {
        guard isCurrentTranscription(requestID, gate: gate) else { return }

        completeTranscription(.success(text), requestID: requestID, gate: gate,
                              locale: locale, backend: backend, startedAt: startedAt)
    }

    func cancelTranscription() {
        lock.lock()
        transcriptionGeneration &+= 1
        let gate = activeTranscriptionGate
        let legacy = activeLegacyTask
        let modern = activeModernTask
        activeTranscriptionGate = nil
        activeLegacyTask = nil
        activeModernTask = nil
        lock.unlock()
        legacy?.cancel(); modern?.cancel()
        gate?.complete(.failure(TranscriptionCancelledError()))
    }

    private func completeTranscription(
        _ result: Result<String, Error>,
        requestID: Int,
        gate: CompletionGate,
        locale: Locale,
        backend: String,
        startedAt: Date
    ) {
        lock.lock()
        guard transcriptionGeneration == requestID, activeTranscriptionGate === gate else {
            lock.unlock()
            return
        }
        activeTranscriptionGate = nil
        activeLegacyTask = nil
        activeModernTask = nil
        lock.unlock()

        let elapsed = Date().timeIntervalSince(startedAt)
        logInfo("SpeechStreamer", "backend=\(backend) locale=\(locale.identifier) final latency_ms=\(Int(elapsed * 1000))")
        gate.complete(result)
    }

    private func isCurrentTranscription(_ requestID: Int, gate: CompletionGate) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return transcriptionGeneration == requestID && activeTranscriptionGate === gate
    }

    // MARK: - Helpers

    static func locale(for language: String?) -> Locale {
        switch language {
        case "zh": return Locale(identifier: "zh-TW")
        case "en": return Locale(identifier: "en-US")
        case "ja": return Locale(identifier: "ja-JP")
        case "ko": return Locale(identifier: "ko-KR")
        default:   return Locale(identifier: "zh-TW")
        }
    }
}
