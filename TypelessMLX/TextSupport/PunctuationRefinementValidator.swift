import Foundation

public enum PunctuationRefinementFailure: Equatable {
    case emptyOutput
    case controlCharacter
    case controlMarker
    case lexicalContentChanged
    case whitespaceChanged
    case symbolChanged
    case originalPunctuationChanged
    case semanticPunctuationAdded
    case timeout
    case unavailable
    case refinementFailed
}

public struct PunctuationRefinementValidation: Equatable {
    public let isValid: Bool
    public let failure: PunctuationRefinementFailure?

    public init(isValid: Bool, failure: PunctuationRefinementFailure? = nil) {
        self.isValid = isValid
        self.failure = failure
    }
}

/// Both the input to punctuation cleanup and the accepted output stay visible to the caller.
public struct PunctuationRefinementOutcome: Equatable {
    public let inputText: String
    public let text: String
    public let wasRefined: Bool
    public let failure: PunctuationRefinementFailure?

    public init(inputText: String, text: String, wasRefined: Bool, failure: PunctuationRefinementFailure? = nil) {
        self.inputText = inputText
        self.text = text
        self.wasRefined = wasRefined
        self.failure = failure
    }
}

/// Accepts punctuation additions while preserving words, numbers, spacing,
/// symbols, and every punctuation mark that already had meaning in the source.
public struct PunctuationRefinementValidator {
    public init() {}

    public func validate(original: String, refined: String) -> PunctuationRefinementValidation {
        guard !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(isValid: false, failure: .emptyOutput)
        }
        if refined.unicodeScalars.contains(where: Self.isControlScalar) {
            return .init(isValid: false, failure: .controlCharacter)
        }
        if Self.containsControlMarker(refined) {
            return .init(isValid: false, failure: .controlMarker)
        }

        let originalParts = Self.signature(original)
        let refinedParts = Self.signature(refined)
        guard originalParts.lexicalTokens == refinedParts.lexicalTokens else {
            return .init(isValid: false, failure: .lexicalContentChanged)
        }
        guard originalParts.whitespace == refinedParts.whitespace else {
            return .init(isValid: false, failure: .whitespaceChanged)
        }
        guard originalParts.opaqueSymbols == refinedParts.opaqueSymbols else {
            return .init(isValid: false, failure: .symbolChanged)
        }
        guard Self.isSubsequence(originalParts.punctuation, of: refinedParts.punctuation) else {
            return .init(isValid: false, failure: .originalPunctuationChanged)
        }
        let additions = Self.addedPunctuation(from: originalParts.punctuation, in: refinedParts.punctuation)
        guard additions.allSatisfy({ Self.allowedAddedPunctuation.contains($0.scalar) }) else {
            return .init(isValid: false, failure: .semanticPunctuationAdded)
        }
        guard !additions.contains(where: { item in
            let position = item.tokenCount
            if position == 0 {
                return refinedParts.numericTokens.first == true
            }
            if position >= refinedParts.numericTokens.count {
                return false
            }
            return refinedParts.numericTokens[position - 1] && refinedParts.numericTokens[position]
        }) else {
            return .init(isValid: false, failure: .semanticPunctuationAdded)
        }
        return .init(isValid: true)
    }

    private struct AnchoredScalar: Equatable {
        let tokenCount: Int
        let scalar: String
    }

    private struct AnchoredWhitespace: Equatable {
        let tokenCount: Int
        var text: String
    }

    private struct Signature {
        var lexicalTokens: [String] = []
        var numericTokens: [Bool] = []
        var whitespace: [AnchoredWhitespace] = []
        var punctuation: [AnchoredScalar] = []
        var opaqueSymbols: [AnchoredScalar] = []
    }

    private static let controlMarkers = [
        "<|", "|>", "[INST]", "[/INST]", "<<SYS>>", "<</SYS>>",
        "```", "assistant:", "user:"
    ]

    private static let allowedAddedPunctuation: Set<String> = [
        ",", "，", "、", ".", "。", "?", "？", "!", "！", "…"
    ]

    private static func containsControlMarker(_ text: String) -> Bool {
        controlMarkers.contains { marker in
            text.range(of: marker, options: [.caseInsensitive]) != nil
        }
    }

    private static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate:
            return true
        default:
            return CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func signature(_ text: String) -> Signature {
        var result = Signature()
        var activeToken = String()
        var activeTokenKind: Int?

        func flushToken() {
            guard !activeToken.isEmpty else { return }
            result.lexicalTokens.append(activeToken)
            result.numericTokens.append(activeToken.unicodeScalars.allSatisfy {
                CharacterSet.decimalDigits.contains($0)
            })
            activeToken = ""
            activeTokenKind = nil
        }

        var index = text.unicodeScalars.startIndex
        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            let scalarString = String(scalar)

            if isLetterOrNumber(scalar) {
                if isCJKScalar(scalar) {
                    flushToken()
                    result.lexicalTokens.append(scalarString)
                    result.numericTokens.append(CharacterSet.decimalDigits.contains(scalar))
                } else {
                    let tokenKind = scalar.value < 128 ? 0 : 1
                    if let activeTokenKind, activeTokenKind != tokenKind { flushToken() }
                    activeTokenKind = tokenKind
                    activeToken.append(contentsOf: scalarString)
                }
            } else if isCombiningMark(scalar), !activeToken.isEmpty {
                activeToken.append(contentsOf: scalarString)
            } else {
                flushToken()
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if let lastIndex = result.whitespace.indices.last,
                       result.whitespace[lastIndex].tokenCount == result.lexicalTokens.count {
                        result.whitespace[lastIndex].text.append(contentsOf: scalarString)
                    } else {
                        result.whitespace.append(.init(tokenCount: result.lexicalTokens.count, text: scalarString))
                    }
                } else if CharacterSet.punctuationCharacters.contains(scalar) {
                    result.punctuation.append(.init(tokenCount: result.lexicalTokens.count, scalar: scalarString))
                } else {
                    result.opaqueSymbols.append(.init(tokenCount: result.lexicalTokens.count, scalar: scalarString))
                }
            }

            index = text.unicodeScalars.index(after: index)
        }
        flushToken()
        return result
    }

    private static func isSubsequence(_ candidate: [AnchoredScalar], of source: [AnchoredScalar]) -> Bool {
        guard candidate.count <= source.count else { return false }
        var candidateIndex = 0
        for item in source where candidateIndex < candidate.count {
            if item == candidate[candidateIndex] { candidateIndex += 1 }
        }
        return candidateIndex == candidate.count
    }

    private static func addedPunctuation(from original: [AnchoredScalar], in refined: [AnchoredScalar]) -> [AnchoredScalar] {
        var originalIndex = 0
        var additions: [AnchoredScalar] = []
        for item in refined {
            if originalIndex < original.count, item == original[originalIndex] {
                originalIndex += 1
            } else {
                additions.append(item)
            }
        }
        return additions
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x2E80...0x2FFF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0x3100...0x312F).contains(value)
            || (0x3130...0x318F).contains(value)
            || (0x31A0...0x31FF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xA960...0xA97F).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x3134F).contains(value)
    }
}

/// Applies the same hesitation cleanup rules as the Python backend.
public enum TextCleanup {
    private static let hesitationPattern = try! NSRegularExpression(
        pattern: "(?<![^\\s，。！？、])(?:呃+|嗯+|啊+|哦+|喔+|哎+)(?=[,，。！？、\\s]|$)"
    )
    private static let duplicatePunctuationPattern = try! NSRegularExpression(pattern: "[，、]\\s*[，、]")
    private static let leadingPunctuationPattern = try! NSRegularExpression(pattern: "^\\s*[，。、！？]\\s*")

    public static func removingHesitations(_ text: String) -> String {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = hesitationPattern.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        var range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = duplicatePunctuationPattern.stringByReplacingMatches(in: result, range: range, withTemplate: "，")
        range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = leadingPunctuationPattern.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
