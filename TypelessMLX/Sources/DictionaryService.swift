import Foundation
import TypelessMLXTextSupport

/// Manages a user-defined vocabulary list that is injected into the Whisper initial_prompt
/// to bias recognition toward domain-specific terms (proper nouns, abbreviations, etc.).
class DictionaryService {
    static let shared = DictionaryService()
    private let correctionStore: VocabularyRuleStore
    private init() {
        correctionStore = VocabularyRuleStore(defaults: .standard, storageKey: "userVocabularyCorrections")
    }

    private let key = "userDictionary"

    var rawTerms: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var terms: [String] {
        rawTerms.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Manually approved ASR corrections. Each rule keeps its source history ID.
    var correctionRules: [VocabularyRule] {
        correctionStore.rules
    }

    @discardableResult
    func addReplacement(
        wrong: String,
        right: String,
        sourceHistoryID: UUID,
        chineseBoundaryConfirmed: Bool = false
    ) -> VocabularyRule? {
        correctionStore.addRule(
            wrong: wrong,
            right: right,
            sourceHistoryID: sourceHistoryID,
            chineseBoundaryConfirmed: chineseBoundaryConfirmed
        )
    }

    @discardableResult
    func setReplacementEnabled(id: UUID, enabled: Bool) -> Bool {
        correctionStore.setEnabled(ruleID: id, isEnabled: enabled)
    }

    @discardableResult
    func deleteReplacement(id: UUID) -> Bool {
        correctionStore.delete(ruleID: id)
    }

    @discardableResult
    func undoLastReplacementDeletion() -> VocabularyRule? {
        correctionStore.undoLastDelete()
    }

    /// Applies confirmed corrections once and returns text before and after replacement.
    func applyReplacementsDetailed(_ text: String) -> VocabularyApplicationResult {
        correctionStore.apply(text)
    }

    func applyReplacements(_ text: String) -> String {
        applyReplacementsDetailed(text).text
    }

    /// Builds the final Whisper prompt by appending dictionary terms to the user's base prompt.
    /// Total result is capped at 600 characters to stay within Whisper's prompt limit.
    func buildPrompt(basePrompt: String) -> String {
        let dictPart = terms.prefix(40).joined(separator: "、")
        if dictPart.isEmpty { return basePrompt }
        let combined = basePrompt.isEmpty ? dictPart : "\(basePrompt) \(dictPart)"
        return String(combined.prefix(600))
    }
}
