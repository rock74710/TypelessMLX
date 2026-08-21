import Foundation

/// The native Apple speech backend selected for a request.
public enum NativeSpeechBackend {
    case modern
    case legacy
}

/// Pure policy decisions shared by the native speech backends.
///
/// This type deliberately has no dependency on Speech.framework.  The app can
/// therefore make locale and routing decisions in code that is also usable by
/// offline tests and by older macOS deployment targets.
public enum SpeechBackendPolicy {
    /// Returns the supported locale whose normalized BCP-47 identifier exactly
    /// matches the requested locale.  In particular, a locale with another
    /// region (for example `zh-CN` or `zh-HK`) is never treated as `zh-TW`.
    public static func exactSupportedLocale<C: Collection>(
        requested: Locale,
        supported: C
    ) -> Locale? where C.Element == Locale {
        let requestedIdentifier = normalizedIdentifier(for: requested)
        guard requestedIdentifier != nil else { return nil }

        return supported.first { locale in
            normalizedIdentifier(for: locale) == requestedIdentifier
        }
    }

    /// Normalizes user dictionary terms for use as contextual strings.
    ///
    /// Terms are trimmed, empty terms are ignored, duplicate terms are
    /// removed while preserving their first-seen order, and each term is
    /// limited to `maxLength` extended grapheme clusters.  The result contains
    /// at most `maxCount` terms.
    public static func normalizedContextualStrings(
        _ strings: [String],
        maxCount: Int = 40,
        maxLength: Int = 80
    ) -> [String] {
        guard maxCount > 0, maxLength > 0 else { return [] }

        var result: [String] = []
        result.reserveCapacity(min(strings.count, maxCount))
        var seen = Set<String>()

        for string in strings {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let term = String(trimmed.prefix(maxLength))
            guard !term.isEmpty, seen.insert(term).inserted else { continue }

            result.append(term)
            if result.count == maxCount { break }
        }

        return result
    }

    /// Whether a request can use the modern native speech backend.
    public static func shouldUseModern<C: Collection>(
        isAvailable: Bool,
        requested: Locale,
        supported: C
    ) -> Bool where C.Element == Locale {
        guard isAvailable else { return false }
        return exactSupportedLocale(requested: requested, supported: supported) != nil
    }

    private static func normalizedIdentifier(for locale: Locale) -> String? {
        normalizedIdentifier(locale.identifier)
    }

    private static func normalizedIdentifier(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Locale.identifier may use the legacy underscore separator.  Accept
        // that spelling, but compare the resulting BCP-47 subtags strictly;
        // do not use Locale's language/region fallback or equivalence rules.
        let bcp47 = trimmed.replacingOccurrences(of: "_", with: "-")
        let subtags = bcp47.split(separator: "-", omittingEmptySubsequences: false)
        guard !subtags.isEmpty, subtags.allSatisfy({ !$0.isEmpty }) else { return nil }

        let normalized = subtags.map(String.init).enumerated().map { index, subtag in
            if index == 0 {
                return subtag.lowercased()
            }

            // BCP-47 script subtags are title-cased.  Region and all other
            // subtags are case-insensitive; lower-casing them gives a stable
            // comparison while retaining their exact semantic identity.
            if subtag.count == 4, subtag.unicodeScalars.allSatisfy(Self.isASCIILetter) {
                return subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased()
            }
            return subtag.lowercased()
        }.joined(separator: "-")

        guard isValidBCP47Identifier(normalized) else { return nil }
        return normalized
    }

    private static func isValidBCP47Identifier(_ identifier: String) -> Bool {
        let subtags = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = subtags.first,
              language.count >= 2,
              language.count <= 8,
              language.unicodeScalars.allSatisfy(Self.isASCIILetter) else {
            return false
        }

        // A locale identifier containing a Unicode extension or private-use
        // subtag is still a valid BCP-47 identifier.  Validate the generic
        // subtag shape without applying locale equivalence or fallback.
        for subtag in subtags.dropFirst() {
            let length = subtag.count
            let isAlphaNumeric = subtag.unicodeScalars.allSatisfy(Self.isASCIIAlphaNumeric)
            guard length >= 1, length <= 8, isAlphaNumeric else { return false }
        }

        return true
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || (48...57).contains(scalar.value)
    }
}
