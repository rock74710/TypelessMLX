import Foundation
import AVFoundation
import TypelessMLXAudioTapSupport
import TypelessMLXTextSupport

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func close(_ actual: Float, _ expected: Float, tolerance: Float = 0.0001) -> Bool {
    abs(actual - expected) <= tolerance
}

func floatBuffer(channels: AVAudioChannelCount, interleaved: Bool = false, frames: AVAudioFrameCount = 8) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: channels,
        interleaved: interleaved
    ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw NSError(domain: "TypelessMLXGainAndTextTests", code: 1)
    }
    buffer.frameLength = frames
    return buffer
}

func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    return list.flatMap { audioBuffer in
        let pointer = audioBuffer.mData!.assumingMemoryBound(to: Float.self)
        let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

func setSamples(_ values: [Float], in buffer: AVAudioPCMBuffer) {
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    var valueIndex = 0
    for audioBuffer in list {
        let pointer = audioBuffer.mData!.assumingMemoryBound(to: Float.self)
        let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        for sampleIndex in 0..<count {
            pointer[sampleIndex] = values[valueIndex]
            valueIndex += 1
        }
    }
    expect(valueIndex == values.count, "sample count must match buffer storage")
}

func testGainZeroAndDecibelSteps() throws {
    let processor = AudioGainProcessor()
    let buffer = try floatBuffer(channels: 1)
    setSamples([0.0, 0.1, -0.1, 0.25, -0.25, 0.5, -0.5, 1.0], in: buffer)
    let original = samples(buffer)

    let zero = processor.process(buffer)
    expect(samples(buffer) == original, "0 dB must preserve finite in-range samples")
    expect(zero.clippingRatio == 0, "0 dB input must not report clipping")

    processor.gainDB = 6
    let sixDBBuffer = try floatBuffer(channels: 1)
    setSamples([0.0, 0.1, -0.1, 0.25, -0.25, 0.5, -0.5, 1.0], in: sixDBBuffer)
    _ = processor.process(sixDBBuffer)
    let sixDBSamples = samples(sixDBBuffer)
    expect(close(sixDBSamples[1], 0.19952623), "+6 dB must apply 10^(dB/20)")
    expect(close(sixDBSamples[3], 0.49881557), "+6 dB amplitude must be about twice the input")

    processor.gainDB = 12
    expect(processor.gainDB == 12, "+12 dB must be accepted")
    let twelveDBBuffer = try floatBuffer(channels: 1)
    setSamples([0.05, -0.05, 0.1, -0.1, 0.2, -0.2, 0.24, -0.24], in: twelveDBBuffer)
    _ = processor.process(twelveDBBuffer)
    expect(close(samples(twelveDBBuffer)[0], 0.19905359), "+12 dB must apply the 12 dB amplitude ratio")
    processor.gainDB = 2
    expect(processor.gainDB == 3, "gain must snap to a 3 dB step")
    processor.gainDB = -20
    expect(processor.gainDB == -6, "gain must clamp at -6 dB")
}

func testInterleavedChannelsAndClipping() throws {
    let processor = AudioGainProcessor()
    processor.gainDB = 6
    let buffer = try floatBuffer(channels: 2, interleaved: true, frames: 3)
    setSamples([0.1, -0.1, 0.6, -0.6, 0.2, -0.2], in: buffer)

    let result = processor.process(buffer)
    let actual = samples(buffer)
    expect(close(actual[0], 0.19952623) && close(actual[1], -0.19952623), "gain must cover both interleaved channels")
    expect(actual[2] == 1 && actual[3] == -1, "samples outside the valid range must be clipped")
    expect(result.clippedSamples == 2, "clipping count must include both channels")
    expect(abs(result.clippingRatio - 2.0 / 6.0) < 0.0001, "clipping ratio must use all interleaved samples")
}

func testNonFiniteAudioDoesNotLeak() throws {
    let processor = AudioGainProcessor()
    let buffer = try floatBuffer(channels: 1, frames: 4)
    setSamples([Float.nan, Float.infinity, -Float.infinity, 0.25], in: buffer)

    let result = processor.process(buffer)
    let actual = samples(buffer)
    expect(actual[0] == 0 && actual[1] == 0 && actual[2] == 0, "non-finite samples must become silence")
    expect(close(actual[3], 0.25), "finite samples must remain usable")
    expect(result.nonFiniteSamples == 3, "processor must count replaced non-finite samples")
    expect(actual.allSatisfy(\.isFinite), "processor must not output NaN or infinity")
}

func testRMSIncludesEveryInterleavedChannel() throws {
    let processor = AudioGainProcessor()
    let buffer = try floatBuffer(channels: 2, interleaved: true, frames: 2)
    setSamples([0, 0.5, 0, 0.5], in: buffer)

    let result = processor.process(buffer)
    expect(result.sampleCount == 4, "RMS sample count must include both channels")
    expect(abs(result.normalizedRMS - sqrt(0.125)) < 0.0001, "RMS must include the non-silent second channel")
}

func testVocabularyCascadeAndBoundaries() throws {
    let rules = [
        VocabularyRule(wrong: "alpha", right: "beta", sourceHistoryID: UUID()),
        VocabularyRule(wrong: "beta", right: "gamma", sourceHistoryID: UUID()),
        VocabularyRule(wrong: "AI", right: "Artificial Intelligence", sourceHistoryID: UUID())
    ]
    let corrector = VocabularyCorrector(rules: rules)
    let result = corrector.apply("alpha beta AI 中AI文")
    expect(result.text == "beta gamma Artificial Intelligence 中AI文", "replacement must be single pass with full Unicode word boundaries")
}

func testLongestRuleAndCasePolicy() {
    let corrector = VocabularyCorrector(rules: [
        VocabularyRule(wrong: "new york", right: "NYC", sourceHistoryID: UUID()),
        VocabularyRule(wrong: "new", right: "Old", sourceHistoryID: UUID())
    ])
    expect(corrector.apply("New York new york NEW").text == "NYC NYC Old", "matching must ignore case and output the saved replacement spelling")
}

func testChineseRulesRequireConfirmedBoundary() {
    let blocked = VocabularyRule(wrong: "小明", right: "曉明", sourceHistoryID: UUID())
    let allowed = VocabularyRule(wrong: "小明", right: "曉明", sourceHistoryID: UUID(), chineseBoundaryConfirmed: true)
    expect(VocabularyCorrector(rules: [blocked]).apply("小明來了").text == "小明來了", "Chinese rules must stay inactive without explicit boundary confirmation")
    expect(VocabularyCorrector(rules: [allowed]).apply("小明來了").text == "曉明來了", "confirmed Chinese rules must apply")
}

func testRulePersistenceDeleteUndoAndSourceHistory() throws {
    let suiteName = "TypelessMLXGainAndTextTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let historyID = UUID()
    let store = VocabularyRuleStore(defaults: defaults, storageKey: "rules")
    let rule = store.addRule(wrong: "typless", right: "Typeless", sourceHistoryID: historyID)
    expect(rule?.sourceHistoryID == historyID, "rule must keep its source history ID")
    expect(store.rules.first?.isEnabled == true, "new rules must start enabled")

    let reloaded = VocabularyRuleStore(defaults: defaults, storageKey: "rules")
    expect(reloaded.rules.first?.id == rule?.id, "rules must survive reload")
    expect(reloaded.setEnabled(ruleID: rule!.id, isEnabled: false), "rule enable state must be editable")
    expect(reloaded.apply("typless").text == "typless", "disabled rules must not apply")
    expect(reloaded.setEnabled(ruleID: rule!.id, isEnabled: true), "rule can be enabled again")
    expect(reloaded.delete(ruleID: rule!.id), "delete must remove a rule")
    expect(reloaded.rules.isEmpty, "deleted rule must not apply")
    expect(reloaded.undoLastDelete()?.id == rule?.id, "last deletion must be undoable")
    expect(reloaded.apply("typless").text == "Typeless", "undo must restore the rule")
}

func testPunctuationValidationProtectsMeaningAndControls() {
    let validator = PunctuationRefinementValidator()
    let preservedDecimal = validator.validate(original: "今天3.14公斤", refined: "今天，3.14公斤。")
    expect(preservedDecimal.isValid, "added punctuation must preserve decimals: \(String(describing: preservedDecimal.failure))")
    expect(!validator.validate(original: "今天3.14公斤", refined: "今天，314公斤。").isValid, "decimal points must not be removed")
    expect(validator.validate(original: "-5 不要改", refined: "-5， 不要改。").isValid, "original minus and negation must survive")
    expect(!validator.validate(original: "-5 不要改", refined: "5，改。").isValid, "minus and negation changes must be rejected")
    expect(!validator.validate(original: "5", refined: "-5").isValid, "a new minus sign must be rejected")
    expect(!validator.validate(original: "5", refined: "+5").isValid, "a new plus sign must be rejected")
    expect(!validator.validate(original: "12 30", refined: "12: 30").isValid, "a new time or ratio colon must be rejected")
    expect(validator.validate(original: "你好世界", refined: "你，好世界。").isValid, "punctuation between Chinese characters must be allowed")
    expect(validator.validate(original: "Hello world", refined: "Hello, world!").isValid, "punctuation edits must be allowed")
    expect(!validator.validate(original: "Hello", refined: "Hello world").isValid, "added words must be rejected")
    expect(!validator.validate(original: "Hello", refined: "Hello<|assistant|>").isValid, "control markers must be rejected")
    expect(!validator.validate(original: "Hello", refined: " \n ").isValid, "empty outputs and control characters must be rejected")
}

func testHesitationCleanupMatchesBackendRules() {
    expect(TextCleanup.removingHesitations("嗯，我想買咖啡。") == "我想買咖啡。", "leading hesitation and punctuation must be removed")
    expect(TextCleanup.removingHesitations("呃，嗯、我想去。") == "我想去。", "adjacent hesitation marks must collapse like backend cleanup")
    expect(TextCleanup.removingHesitations("我就是想要這個") == "我就是想要這個", "normal phrase words must remain")
    expect(TextCleanup.removingHesitations("這個嗯很好") == "這個嗯很好", "a hesitation token without backend boundaries must remain")
}

final class AsyncTestValueBox {
    private let lock = NSLock()
    private var storedValue: String?

    func set(_ value: String?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

func nonCooperativeLateValue() async -> String {
    await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            continuation.resume(returning: "late")
        }
    }
}

func testAsyncTimeoutDoesNotWaitForLateWork() {
    let completed = DispatchSemaphore(value: 0)
    let box = AsyncTestValueBox()
    let start = Date()
    Task {
        let result = await AsyncTimeout.run(timeoutNanoseconds: 20_000_000) {
            await nonCooperativeLateValue()
        }
        box.set(result)
        completed.signal()
    }

    expect(completed.wait(timeout: .now() + 0.3) == .success, "timeout must return while non-cooperative work is still running")
    expect(box.value == nil, "timed out work must fall back without a late value")
    expect(Date().timeIntervalSince(start) < 0.3, "timeout must not wait for the model operation")
}

func testAsyncTimeoutRespondsToParentCancellation() {
    let completed = DispatchSemaphore(value: 0)
    let box = AsyncTestValueBox()
    let start = Date()
    let task = Task {
        let result = await AsyncTimeout.run(timeoutNanoseconds: 1_000_000_000) {
            await nonCooperativeLateValue()
        }
        box.set(result)
        completed.signal()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
        task.cancel()
    }

    expect(completed.wait(timeout: .now() + 0.3) == .success, "parent cancellation must release the pending refinement")
    expect(box.value == nil, "cancellation must use the input fallback")
    expect(Date().timeIntervalSince(start) < 0.3, "parent cancellation must not wait for the model operation")
}

try testGainZeroAndDecibelSteps()
try testInterleavedChannelsAndClipping()
try testNonFiniteAudioDoesNotLeak()
try testRMSIncludesEveryInterleavedChannel()
try testVocabularyCascadeAndBoundaries()
testLongestRuleAndCasePolicy()
testChineseRulesRequireConfirmedBoundary()
try testRulePersistenceDeleteUndoAndSourceHistory()
testPunctuationValidationProtectsMeaningAndControls()
testHesitationCleanupMatchesBackendRules()
testAsyncTimeoutDoesNotWaitForLateWork()
testAsyncTimeoutRespondsToParentCancellation()
print("TypelessMLXGainAndTextTests passed")
