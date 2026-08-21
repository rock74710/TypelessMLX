import Foundation
import TypelessMLXSpeechBackendPolicy

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func testExactTaiwanLocaleMatch() {
    let requested = Locale(identifier: "zh-TW")
    let taiwan = Locale(identifier: "zh-TW")
    let supported = [
        Locale(identifier: "zh-CN"),
        taiwan,
        Locale(identifier: "en-US")
    ]

    expect(
        SpeechBackendPolicy.exactSupportedLocale(requested: requested, supported: supported) == taiwan,
        "zh-TW should match the exact supported locale"
    )
}

func testOtherChineseRegionsDoNotMatchTaiwan() {
    let requested = Locale(identifier: "zh-TW")

    expect(
        SpeechBackendPolicy.exactSupportedLocale(
            requested: requested,
            supported: [Locale(identifier: "zh-CN")]
        ) == nil,
        "zh-CN must not be treated as zh-TW"
    )
    expect(
        SpeechBackendPolicy.exactSupportedLocale(
            requested: requested,
            supported: [Locale(identifier: "zh-HK")]
        ) == nil,
        "zh-HK must not be treated as zh-TW"
    )
}

func testModernAvailabilityAndLocaleGate() {
    let requested = Locale(identifier: "zh-TW")
    let supported = [Locale(identifier: "zh-TW")]

    expect(
        SpeechBackendPolicy.shouldUseModern(
            isAvailable: true,
            requested: requested,
            supported: supported
        ),
        "an available modern backend with an exact locale should be selected"
    )
    expect(
        !SpeechBackendPolicy.shouldUseModern(
            isAvailable: false,
            requested: requested,
            supported: supported
        ),
        "an unavailable modern backend should fall back to legacy"
    )
    expect(
        !SpeechBackendPolicy.shouldUseModern(
            isAvailable: true,
            requested: requested,
            supported: [Locale(identifier: "zh-CN")]
        ),
        "an unsupported exact locale should fall back to legacy"
    )
}

func testLocaleNormalizationIsCaseAndSeparatorStableButStrict() {
    let requested = Locale(identifier: "zh-TW")
    expect(
        SpeechBackendPolicy.exactSupportedLocale(
            requested: requested,
            supported: [Locale(identifier: "zh_tw")]
        ) != nil,
        "BCP-47 case and legacy separator spelling should normalize consistently"
    )
    expect(
        SpeechBackendPolicy.exactSupportedLocale(
            requested: requested,
            supported: [Locale(identifier: "zh-Hant-TW")]
        ) == nil,
        "a locale with an additional script subtag must not be substituted"
    )
}

func testContextualStringNormalization() {
    let longTerm = String(repeating: "語", count: 81)
    let normalized = SpeechBackendPolicy.normalizedContextualStrings(
        ["  Apple  ", "", "Apple", "\n", "Breeze", longTerm, "Qwen"],
        maxCount: 4,
        maxLength: 80
    )

    expect(
        normalized == ["Apple", "Breeze", String(longTerm.prefix(80)), "Qwen"],
        "contextual strings should trim, deduplicate, truncate, and preserve order"
    )
    expect(
        normalized.allSatisfy { $0.count <= 80 },
        "each contextual string should obey the length cap"
    )

    let capped = SpeechBackendPolicy.normalizedContextualStrings(
        ["one", "two", "three"],
        maxCount: 2,
        maxLength: 80
    )
    expect(capped == ["one", "two"], "contextual strings should obey the count cap")
    expect(
        SpeechBackendPolicy.normalizedContextualStrings(["ignored"], maxCount: 0) == [],
        "a non-positive count cap should produce no context"
    )
}

testExactTaiwanLocaleMatch()
testOtherChineseRegionsDoNotMatchTaiwan()
testModernAvailabilityAndLocaleGate()
testLocaleNormalizationIsCaseAndSeparatorStableButStrict()
testContextualStringNormalization()
print("TypelessMLXSpeechBackendPolicyTests passed")
