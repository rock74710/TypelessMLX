# TICKET-001：macOS 26 新 Speech final backend

## 目標

在保留既有 `SpeechStreamer` 對外介面的前提下，新增 macOS 26+ 的 `SpeechAnalyzer`／`SpeechTranscriber` 檔案辨識路徑；任何能力、locale、asset 或執行錯誤都安全回退至既有 `SFSpeechRecognizer`。

## 範圍

- 新增獨立 modern backend type，避免把 availability 分支散落在 UI。
- 僅接受精確 `zh-TW`、`en-US`、`ja-JP`、`ko-KR` locale；若 `supportedLocale(equivalentTo:)` 回傳其他 region，不可靜默替代。
- 檢查 `SpeechTranscriber.isAvailable`、`supportedLocales` 與 `installedLocales`。
- 使用 `AssetInventory.assetInstallationRequest` 安裝缺少但支援的 asset，並處理失敗。
- 使用 `SpeechAnalyzer(inputAudioFile:modules:analysisContext:finishAfterFile:)` 或等價 API 取得 final results。
- 將 final result 正確合併；空結果視為失敗並回退 legacy。
- 提供 backend 選擇／fallback reason log。
- 保持現有 legacy streaming preview 行為。

## 非目標

- 本 Ticket 不把 live PCM buffer 改成 `AnalyzerInput` streaming。
- 不改 Breeze／Python backend。
- 不更動設定 UI。

## 驗收

- macOS 26+ 支援且可取得 asset 時走 modern backend。
- modern backend 任一階段失敗時，completion 只呼叫一次並走 legacy。
- macOS 13–15 編譯時不引用不可用 symbol。
- concurrent/cancelled request 不會把舊結果回傳給新請求。
- Release build 通過。

## 檔案所有權

- `TypelessMLX/Sources/ModernSpeechTranscriber.swift`（新增）
- `TypelessMLX/Sources/SpeechStreamer.swift`

