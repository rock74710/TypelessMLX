#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
for target in TypelessMLXAudioTapFormatTests TypelessMLXAudioInputAvailabilityTests TypelessMLXHotkeySupportTests TypelessMLXSpeechBackendPolicyTests TypelessMLXWorkflowTests TypelessMLXGainAndTextTests; do
    "$bin_dir/$target"
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/typelessmlx-tests.XXXXXX")"
trap 'rm -f "$scratch/bridge-tests" "$scratch/model-tests"; rmdir "$scratch"' EXIT
swiftc TypelessMLX/Sources/WhisperBridge.swift TypelessMLX/Tests/Bridge/main.swift -o "$scratch/bridge-tests"
"$scratch/bridge-tests"
swiftc TypelessMLX/Sources/ModelReadiness.swift TypelessMLX/Tests/ModelReadiness/main.swift -o "$scratch/model-tests"
"$scratch/model-tests"
python3 -m unittest discover -s backend -p 'test_*.py'
