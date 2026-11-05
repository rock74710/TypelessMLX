2026-11-05T11:17:39+0800

# Gain and vocabulary implementation report

Revision: 1

## Summary

- D and E support code is complete. Audio gain runs once before file writing, metering, and live preview.
- Vocabulary rules support one-pass replacement, Unicode-aware English boundaries, Chinese confirmation, persistence, deletion, and undo.
- The targeted gain and text executable passes. Live microphone quality and Apple model behavior remain unverified.

## Implementation

- `AudioGainProcessor` supports Float32, Float64, Int16, and Int32 buffers. It preserves channel layout and applies gain in place.
- Gain uses −6 to +12 dB in 3 dB steps. The default is 0 dB. The meter reads normalized RMS from the same pass.
- The recorder exposes `setInputGainDB(_:)`, `gainChanges`, and `clippingHandler`. It reports clipping when a buffer clips at least 1% of its samples.
- `forceReset()` removes current and pending audio files. A late stop callback returns no URL after cancellation.
- `VocabularyRuleStore` stores version 1 rules and the undo stack in UserDefaults. Each rule stores its source history ID.
- Rules match case-insensitively and use the saved replacement spelling. The longest match wins. Inserted text is not scanned again.
- Chinese rules stay inactive until `chineseBoundaryConfirmed` is true. English matches use full Unicode letter and number boundaries.
- `TextRefiner` accepts only safe punctuation additions. It preserves lexical text, spacing, symbols, and original punctuation. It rejects new signs, colons, controls, markers, and empty output.
- `AsyncTimeout` returns on timeout or parent cancellation. It does not wait for a model operation that ignores cancellation. A late result cannot replace the fallback.
- `TextCleanup.removingHesitations(_:)` matches the current backend hesitation rules. The host calls it when the existing setting is enabled.

## Integration API

- `DictionaryService.applyReplacementsDetailed(_:)` returns the original and substituted text. `applyReplacements(_:)` returns the substituted text.
- Rule UI can use `correctionRules`, `addReplacement`, `setReplacementEnabled`, `deleteReplacement`, and `undoLastReplacementDeletion`.
- `TextRefiner.refineDetailed(_:)` returns the input, final text, acceptance state, and failure reason.
- The host records the initial gain separately. `gainChanges` contains later values set during the recording.

## Validation

- `rtk swift run TypelessMLXGainAndTextTests` passed after implementation.
- Tests cover 0, +6, and +12 dB; gain bounds; interleaved stereo; clipping; non-finite samples; and all-channel RMS.
- Text tests cover longest-match replacement, A→B→C non-chaining, word boundaries, case policy, Chinese confirmation, versioned persistence, delete, and undo.
- Refinement tests cover decimals, minus signs, negation, added signs, colons, controls, markers, empty output, hesitation cleanup, timeout, late work, and parent cancellation.
- The host release build is in progress. This worker did not run the full suite or test a live microphone or Apple model session.

## Closeout

- No commit was made, as instructed.
- The host owns A-001 notebook, STATUS, and route records. No Agentflow command was run.
- The host should complete the release build and review the UI integration before marking D/E complete.

Self-check: Assigned files were reviewed, targeted tests pass, and no commit or Agentflow command was made.
