import Foundation

/// One manually approved correction from an ASR word to the intended text.
public struct VocabularyRule: Codable, Equatable, Identifiable {
    public let id: UUID
    public var wrong: String
    public var right: String
    public var isEnabled: Bool
    public let sourceHistoryID: UUID
    public var chineseBoundaryConfirmed: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        wrong: String,
        right: String,
        sourceHistoryID: UUID,
        isEnabled: Bool = true,
        chineseBoundaryConfirmed: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.wrong = wrong
        self.right = right
        self.sourceHistoryID = sourceHistoryID
        self.isEnabled = isEnabled
        self.chineseBoundaryConfirmed = chineseBoundaryConfirmed
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, wrong, right, isEnabled, sourceHistoryID, chineseBoundaryConfirmed, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        wrong = try values.decode(String.self, forKey: .wrong)
        right = try values.decode(String.self, forKey: .right)
        sourceHistoryID = try values.decode(UUID.self, forKey: .sourceHistoryID)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        chineseBoundaryConfirmed = try values.decodeIfPresent(Bool.self, forKey: .chineseBoundaryConfirmed) ?? false
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }
}

/// The result of one non-chaining pass over the original recognized text.
public struct VocabularyApplicationResult: Equatable {
    public let originalText: String
    public let text: String
    public let appliedRuleIDs: [UUID]

    public init(originalText: String, text: String, appliedRuleIDs: [UUID]) {
        self.originalText = originalText
        self.text = text
        self.appliedRuleIDs = appliedRuleIDs
    }
}

/// Applies the longest enabled match at each position in the source text.
public struct VocabularyCorrector {
    private let rules: [VocabularyRule]

    public init(rules: [VocabularyRule]) {
        self.rules = rules.enumerated()
            .filter { $0.element.isEnabled && Self.isValidRule($0.element) }
            .sorted {
                let leftLength = $0.element.wrong.count
                let rightLength = $1.element.wrong.count
                return leftLength == rightLength ? $0.offset < $1.offset : leftLength > rightLength
            }
            .map(\.element)
    }

    public func apply(_ text: String) -> VocabularyApplicationResult {
        guard !text.isEmpty, !rules.isEmpty else {
            return VocabularyApplicationResult(originalText: text, text: text, appliedRuleIDs: [])
        }

        var output = String()
        output.reserveCapacity(text.utf8.count)
        var appliedIDs: [UUID] = []
        var index = text.startIndex

        while index < text.endIndex {
            var matched: (rule: VocabularyRule, range: Range<String.Index>)?

            for rule in rules where Self.isApplicable(rule) {
                let searchRange = index..<text.endIndex
                guard let range = text.range(
                    of: rule.wrong,
                    options: [.anchored, .caseInsensitive],
                    range: searchRange,
                    locale: Locale(identifier: "en_US_POSIX")
                ), Self.hasCompleteASCIIBoundary(rule.wrong, in: text, range: range) else {
                    continue
                }
                matched = (rule, range)
                break
            }

            if let match = matched {
                output.append(contentsOf: match.rule.right)
                appliedIDs.append(match.rule.id)
                index = match.range.upperBound
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }

        return VocabularyApplicationResult(originalText: text, text: output, appliedRuleIDs: appliedIDs)
    }

    private static func isValidRule(_ rule: VocabularyRule) -> Bool {
        !rule.wrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rule.right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rule.wrong != rule.right
    }

    private static func isApplicable(_ rule: VocabularyRule) -> Bool {
        !containsChinese(rule.wrong) || rule.chineseBoundaryConfirmed
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCJKScalar($0) }
    }

    private static func hasCompleteASCIIBoundary(_ wrong: String, in source: String, range: Range<String.Index>) -> Bool {
        guard let first = wrong.unicodeScalars.first, let last = wrong.unicodeScalars.last else { return false }

        if isASCIIWordScalar(first), range.lowerBound > source.startIndex {
            let previous = source[source.index(before: range.lowerBound)]
            if previous.unicodeScalars.contains(where: isUnicodeLetterOrNumber) { return false }
        }

        if isASCIIWordScalar(last), range.upperBound < source.endIndex {
            let next = source[range.upperBound]
            if next.unicodeScalars.contains(where: isUnicodeLetterOrNumber) { return false }
        }

        return true
    }

    private static func isASCIIWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isUnicodeLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
}

/// A versioned rule store with persistent delete undo.
public final class VocabularyRuleStore {
    private struct StoredRules: Codable {
        var version: Int
        var rules: [VocabularyRule]
        var deletedRules: [VocabularyRule]
    }

    public static let currentVersion = 1

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private var stored: StoredRules

    public init(defaults: UserDefaults = .standard, storageKey: String = "vocabularyCorrectionRules") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(StoredRules.self, from: data),
           decoded.version == Self.currentVersion {
            stored = decoded
        } else {
            stored = StoredRules(version: Self.currentVersion, rules: [], deletedRules: [])
        }
    }

    public var rules: [VocabularyRule] {
        lock.lock()
        defer { lock.unlock() }
        return stored.rules
    }

    @discardableResult
    public func addRule(
        wrong: String,
        right: String,
        sourceHistoryID: UUID,
        chineseBoundaryConfirmed: Bool = false
    ) -> VocabularyRule? {
        let cleanWrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWrong.isEmpty, !cleanRight.isEmpty, cleanWrong != cleanRight else { return nil }

        let rule = VocabularyRule(
            wrong: cleanWrong,
            right: cleanRight,
            sourceHistoryID: sourceHistoryID,
            chineseBoundaryConfirmed: chineseBoundaryConfirmed
        )
        lock.lock()
        stored.rules.append(rule)
        persistLocked()
        lock.unlock()
        return rule
    }

    @discardableResult
    public func setEnabled(ruleID: UUID, isEnabled: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = stored.rules.firstIndex(where: { $0.id == ruleID }) else { return false }
        stored.rules[index].isEnabled = isEnabled
        persistLocked()
        return true
    }

    @discardableResult
    public func delete(ruleID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = stored.rules.firstIndex(where: { $0.id == ruleID }) else { return false }
        let removed = stored.rules.remove(at: index)
        stored.deletedRules.append(removed)
        if stored.deletedRules.count > 50 {
            stored.deletedRules.removeFirst(stored.deletedRules.count - 50)
        }
        persistLocked()
        return true
    }

    @discardableResult
    public func undoLastDelete() -> VocabularyRule? {
        lock.lock()
        defer { lock.unlock() }
        guard let removed = stored.deletedRules.popLast() else { return nil }
        stored.rules.append(removed)
        persistLocked()
        return removed
    }

    public func apply(_ text: String) -> VocabularyApplicationResult {
        VocabularyCorrector(rules: rules).apply(text)
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
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

private func isUnicodeLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
}
