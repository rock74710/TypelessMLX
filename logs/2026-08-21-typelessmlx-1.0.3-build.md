# TypelessMLX 1.0.3 Build Log

- 建置時間：2026-08-21 14:06–14:07 CST
- Git branch：`feat/apple-speech-transcriber`
- Git revision：`65e8e76`
- App version：`1.0.3`
- Bundle build：`4`
- Xcode toolchain：`/Applications/Xcode-beta.app/Contents/Developer`
- 簽章：ad-hoc（本機無有效 Apple code-signing identity）

## 建置

執行：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
ALLOW_ADHOC_SIGNING=1 \
./build-app.sh --allow-adhoc
```

結果：成功。

- Release binary：成功（`swift build -c release`）
- App bundle：`build/TypelessMLX.app`
- App size：約 1.6 MB
- Executable size：約 1.4 MB
- DMG：`build/TypelessMLX-1.0.3.dmg`
- DMG size：840,356 bytes（約 824 KB）

## 簽章與版本驗證

```text
codesign --verify --deep --strict build/TypelessMLX.app: PASS
Designated Requirement: PASS
Signature: ad-hoc
Identifier: com.typelessmlx.app
CFBundleShortVersionString: 1.0.3
CFBundleVersion: 4
```

本機 `security find-identity -v -p codesigning` 回報 `0 valid identities found`，因此這個產物沒有 Developer ID 簽章，也沒有 notarize。公開發行前需以正式 Developer ID 重新簽章並送 Apple notarization。

## DMG 驗證

```text
hdiutil verify build/TypelessMLX-1.0.3.dmg: VALID
SHA-256: 022d65be043cc0de7fb8301fda7fe54b5700342d7a4189af97c1c3a3b052c197
```

`hdiutil create` 成功，但工具輸出棄用警告，建議日後將打包腳本遷移至 `diskutil image create`。

## 測試

以下測試均以 release configuration 執行並通過：

```text
TypelessMLXHotkeySupportTests: PASS
TypelessMLXAudioTapFormatTests: PASS
TypelessMLXAudioInputAvailabilityTests: PASS
TypelessMLXSpeechBackendPolicyTests: PASS
git diff --check: PASS
```

AudioTap 測試期間 AVFoundation 輸出「Audio files cannot be non-interleaved」提示，但測試通過，未影響產物。

## 發行文件

- Release notes：`release-notes/TypelessMLX-1.0.3.md`
- Changelog：`CHANGELOG.md` 的 `1.0.3` 區段
- Feature ticket：`tickets/TICKET-004-customizable-dictation-hotkey.md`

## 工作區說明

本次產物由目前工作區內容建置，工作區包含尚未 commit 的功能修改；既有 `RecordingOverlay.swift` 與其他使用者修改均未回復。
