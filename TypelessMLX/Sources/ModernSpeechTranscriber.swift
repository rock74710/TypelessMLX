import Foundation
import Speech
import AVFoundation
import TypelessMLXSpeechBackendPolicy

/// File-based transcription backed by the macOS 26 Speech framework.
///
/// This type deliberately contains all availability and asset-management code
/// for the modern API. Callers can therefore keep their macOS 13 deployment
/// target and treat any error as a signal to use the legacy recognizer.
@available(macOS 26, *)
final class ModernSpeechTranscriber {
    static let shared = ModernSpeechTranscriber()

    /// The locale list is intentionally small. In particular, an equivalent
    /// locale returned by Speech (for example `zh-HK` for a `zh-TW` request)
    /// must not be silently substituted.
    static let supportedLocaleIdentifiers: Set<String> = [
        "zh-TW", "en-US", "ja-JP", "ko-KR"
    ]

    enum TranscriptionError: LocalizedError {
        case unavailable
        case unsupportedLocale(Locale)
        case unsupportedLocaleReturned(requested: Locale, returned: Locale)
        case assetUnsupported(Locale)
        case assetInstallationUnavailable(Locale)
        case assetInstallationFailed(Locale, Error)
        case audioFileUnavailable(URL, Error)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "SpeechTranscriber 不可用"
            case .unsupportedLocale(let locale):
                return "SpeechTranscriber 不支援精確語系 " + locale.identifier
            case .unsupportedLocaleReturned(let requested, let returned):
                return "SpeechTranscriber 將 " + requested.identifier + " 對應到 " + returned.identifier + "，拒絕替換"
            case .assetUnsupported(let locale):
                return "SpeechTranscriber 沒有 " + locale.identifier + " 的可用 asset"
            case .assetInstallationUnavailable(let locale):
                return "無法取得 " + locale.identifier + " 的 Speech asset 安裝要求"
            case .assetInstallationFailed(let locale, let error):
                return "Speech asset 安裝失敗（" + locale.identifier + "）：" + error.localizedDescription
            case .audioFileUnavailable(let url, let error):
                return "無法讀取音訊檔案 " + url.lastPathComponent + "：" + error.localizedDescription
            case .emptyResult:
                return "SpeechTranscriber 回傳空結果"
            }
        }
    }

    private init() {}

    static var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Transcribes a completed audio file with the exact requested locale.
    ///
    /// This method throws for every capability, locale, asset, I/O, and
    /// inference failure. `SpeechStreamer` owns the fallback decision so it
    /// can guarantee that a request completes through the legacy backend at
    /// most once.
    func transcribe(audioURL: URL, locale requestedLocale: Locale,
                    contextualStrings: [String] = []) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            logWarn("ModernSpeechTranscriber", "backend unavailable")
            throw TranscriptionError.unavailable
        }

        guard let requestedIdentifier = Self.exactIdentifier(for: requestedLocale) else {
            logWarn("ModernSpeechTranscriber", "locale rejected: " + requestedLocale.identifier)
            throw TranscriptionError.unsupportedLocale(requestedLocale)
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        let supportedDescription = supportedLocales.map(\.identifier).joined(separator: ",")
        logInfo("ModernSpeechTranscriber", "locale=" + requestedIdentifier + " supported=[" + supportedDescription + "]")

        guard let policyLocale = SpeechBackendPolicy.exactSupportedLocale(
            requested: requestedLocale,
            supported: supportedLocales
        ), Self.exactIdentifier(for: policyLocale) == requestedIdentifier else {
            throw TranscriptionError.unsupportedLocale(requestedLocale)
        }

        // Check Apple's equivalent-locale helper as well as the raw list. It
        // may return a different region, which is explicitly not acceptable
        // for this app's locale contract.
        if let equivalentLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            guard Self.exactIdentifier(for: equivalentLocale) == requestedIdentifier else {
                logWarn("ModernSpeechTranscriber", "locale substitution refused: requested=" + requestedIdentifier + " returned=" + equivalentLocale.identifier)
                throw TranscriptionError.unsupportedLocaleReturned(
                    requested: requestedLocale,
                    returned: equivalentLocale
                )
            }
        } else {
            throw TranscriptionError.unsupportedLocale(requestedLocale)
        }

        let exactLocale = Locale(identifier: requestedIdentifier)
        let transcriber = SpeechTranscriber(locale: exactLocale, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]

        try await Self.ensureAssets(for: exactLocale, modules: modules)
        try Task.checkCancellation()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscriptionError.audioFileUnavailable(audioURL, error)
        }

        let context = AnalysisContext()
        let normalizedStrings = SpeechBackendPolicy.normalizedContextualStrings(contextualStrings)
        if !normalizedStrings.isEmpty {
            context.contextualStrings[.general] = normalizedStrings
            logInfo("ModernSpeechTranscriber", "contextual strings=" + String(normalizedStrings.count))
        }

        let start = Date()
        logInfo("ModernSpeechTranscriber", "backend=modern locale=\(exactLocale.identifier) asset ready; analyzing \(audioURL.lastPathComponent)")

        // Consume the module's AsyncSequence concurrently with file analysis.
        // The explicit start API is equivalent to the file initializer, while
        // making it impossible to miss early results emitted during setup.
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.setContext(context)
        let resultsTask = Task { () throws -> String in
            var mergedText = ""
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let piece = String(result.text.characters)
                mergedText = Self.mergeFinalText(mergedText, with: piece)
            }
            return mergedText
        }

        let mergedText: String
        do {
            mergedText = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
                return try await resultsTask.value
            }, onCancel: {
                resultsTask.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            })
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let finalText = mergedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = Date().timeIntervalSince(start)
        logInfo("ModernSpeechTranscriber", "backend=modern locale=\(exactLocale.identifier) final chars=\(finalText.count) latency_ms=\(Int(elapsed * 1000))")

        guard !finalText.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return finalText
    }

    // MARK: - Locale and assets

    private static func exactIdentifier(for locale: Locale) -> String? {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let components = identifier.split(separator: "-")
        guard components.count == 2,
              let language = components.first,
              let region = components.last else {
            return nil
        }

        let normalized = "\(language.lowercased())-\(region.uppercased())"
        return supportedLocaleIdentifiers.contains(normalized) ? normalized : nil
    }

    private static func containsExact(_ locale: Locale, in locales: [Locale]) -> Bool {
        guard let identifier = exactIdentifier(for: locale) else { return false }
        return locales.contains { exactIdentifier(for: $0) == identifier }
    }

    private static func ensureAssets(for locale: Locale,
                                     modules: [any SpeechModule]) async throws {
        let installedLocales = await SpeechTranscriber.installedLocales
        if containsExact(locale, in: installedLocales) {
            logInfo("ModernSpeechTranscriber", "asset installed locale=\(locale.identifier)")
            return
        }

        let status = await AssetInventory.status(forModules: modules)
        logInfo("ModernSpeechTranscriber", "asset status locale=\(locale.identifier) status=\(String(describing: status))")
        guard status != .unsupported else {
            throw TranscriptionError.assetUnsupported(locale)
        }

        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: modules)
        } catch {
            throw TranscriptionError.assetInstallationFailed(locale, error)
        }
        guard let request else {
            throw TranscriptionError.assetInstallationUnavailable(locale)
        }

        logInfo("ModernSpeechTranscriber", "asset installation started locale=\(locale.identifier)")
        do {
            try await request.downloadAndInstall()
        } catch {
            throw TranscriptionError.assetInstallationFailed(locale, error)
        }

        let installedAfter = await SpeechTranscriber.installedLocales
        guard containsExact(locale, in: installedAfter) else {
            throw TranscriptionError.assetInstallationUnavailable(locale)
        }
        logInfo("ModernSpeechTranscriber", "asset installation completed locale=\(locale.identifier)")
    }

    // SpeechTranscriber can emit multiple final ranges. In some OS releases a
    // later final result includes the earlier text, while in others it is just
    // the next range; this merge handles both without duplicating cumulative
    // output.
    private static func mergeFinalText(_ existing: String, with incoming: String) -> String {
        let piece = incoming
        guard !piece.isEmpty else { return existing }
        guard !existing.isEmpty else { return piece }

        if piece == existing || existing.hasSuffix(piece) {
            return existing
        }
        if piece.hasPrefix(existing) {
            return piece
        }

        let existingLast = existing.unicodeScalars.last
        let incomingFirst = piece.unicodeScalars.first
        let needsSeparator: Bool
        if let existingLast, let incomingFirst {
            let asciiAlphaNumeric = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            )
            // Chinese, Japanese, and Korean speech should remain contiguous;
            // only insert a separator for adjacent Latin/ASCII terms when the
            // result stream omitted one.
            needsSeparator = asciiAlphaNumeric.contains(existingLast) &&
                asciiAlphaNumeric.contains(incomingFirst)
        } else {
            needsSeparator = false
        }
        return existing + (needsSeparator ? " " : "") + piece
    }
}
