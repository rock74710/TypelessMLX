import Foundation
import TypelessMLXTextSupport

#if canImport(FoundationModels)
import FoundationModels

/// Adds punctuation only. Unsafe model output returns the exact input text.
@available(macOS 26, *)
actor TextRefiner {
    static let shared = TextRefiner()

    static let defaultTimeoutNanoseconds: UInt64 = 10_000_000_000

    private var session: LanguageModelSession?
    private let validator = PunctuationRefinementValidator()

    private init() {}

    func refine(_ text: String) async -> String {
        await refineDetailed(text).text
    }

    func refineDetailed(
        _ text: String,
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds
    ) async -> PunctuationRefinementOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PunctuationRefinementOutcome(
                inputText: text,
                text: text,
                wasRefined: false,
                failure: .emptyOutput
            )
        }

        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            logWarn("TextRefiner", "Apple Intelligence not available: \(availability)")
            return PunctuationRefinementOutcome(inputText: text, text: text, wasRefined: false, failure: .unavailable)
        }

        if session == nil { session = LanguageModelSession() }
        guard let session else {
            return PunctuationRefinementOutcome(inputText: text, text: text, wasRefined: false, failure: .unavailable)
        }

        let prompt = """
以下是語音辨識結果。只加入適當標點符號，不得刪除、替換、增加或重排任何詞彙、數字、空白或已有標點。
請直接輸出結果，不要說明、前言、控制標記或程式碼區塊：
\(text)
"""
        let start = Date()
        guard let response = await responseWithTimeout(
            session: session,
            prompt: prompt,
            timeoutNanoseconds: timeoutNanoseconds
        ) else {
            logWarn("TextRefiner", "Refinement timed out; preserving input")
            return PunctuationRefinementOutcome(inputText: text, text: text, wasRefined: false, failure: .timeout)
        }

        let validation = validator.validate(original: text, refined: response)
        guard validation.isValid else {
            logWarn("TextRefiner", "Rejected unsafe punctuation result: \(String(describing: validation.failure))")
            return PunctuationRefinementOutcome(
                inputText: text,
                text: text,
                wasRefined: false,
                failure: validation.failure ?? .refinementFailed
            )
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        logInfo("TextRefiner", "Refined \(text.count)→\(response.count) chars in \(ms)ms")
        return PunctuationRefinementOutcome(inputText: text, text: response, wasRefined: true)
    }

    /// Uses unstructured tasks so timeout returns even if the model ignores cancellation.
    private func responseWithTimeout(
        session: LanguageModelSession,
        prompt: String,
        timeoutNanoseconds: UInt64
    ) async -> String? {
        await AsyncTimeout.run(timeoutNanoseconds: timeoutNanoseconds) { [session] in
            let response = try await session.respond(to: prompt)
            return response.content
        }
    }

    /// Eagerly initialise the LanguageModelSession so first use has less cold-start delay.
    func warmUp() async {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            logWarn("TextRefiner", "Skipping warm-up — Apple Intelligence not available: \(availability)")
            return
        }
        if session == nil {
            session = LanguageModelSession()
            logInfo("TextRefiner", "Session initialised (warm-up)")
        }
    }
}

#else

// Stub when FoundationModels SDK is unavailable.
@available(macOS 26, *)
actor TextRefiner {
    static let shared = TextRefiner()

    private init() {}

    func refine(_ text: String) async -> String { text }

    func refineDetailed(_ text: String, timeoutNanoseconds: UInt64 = 10_000_000_000) async -> PunctuationRefinementOutcome {
        PunctuationRefinementOutcome(inputText: text, text: text, wasRefined: false, failure: .unavailable)
    }

    func warmUp() async {}
}

#endif
