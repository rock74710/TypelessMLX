# TypelessMLX：Apple 新 Speech API 升級計畫

## 決策

TypelessMLX 採用雙引擎產品策略：

- **快速模式**：macOS 26+ 優先使用 `SpeechAnalyzer` + `SpeechTranscriber`；不支援時回退既有 `SFSpeechRecognizer`。
- **台灣中英高精度模式**：保留 Breeze-ASR-25 作為最終辨識引擎。

Apple 引擎不假設所有 Mac 都支援 `zh-TW`。程式必須在 runtime 檢查硬體能力、精確 locale 與模型 asset 狀態；不得把其他 `zh` region 靜默當成 `zh-TW`。

## 共通驗收標準

- macOS 26+ 且系統回報精確 `zh-TW` 支援時，`macos-speech` 最終辨識使用新 API。
- 新 API 不可用、locale 不支援、asset 安裝失敗或推論失敗時，自動回退 legacy engine，使用者仍能完成聽寫。
- macOS 13–15 必須維持可編譯、可執行。
- 使用者字典會作為 contextual strings 傳入新 API，且有明確數量／長度上限。
- log 必須記錄實際使用的 backend、locale、asset/fallback 原因與 key-up 到 final result 的延遲。
- Breeze 路徑與現有模型選擇不得退化。
- `swift build -c release` 與現有可執行測試全部通過。

## Tickets

| Ticket | 內容 | 相依性 | 狀態 |
|---|---|---|---|
| [TICKET-001](TICKET-001-modern-speech-backend.md) | macOS 26 新 Speech final backend 與 legacy fallback | 無 | ✅ 完成 |
| [TICKET-002](TICKET-002-routing-context-and-telemetry.md) | App 路由、contextual glossary、設定與 telemetry | TICKET-001 的介面 | ✅ 完成 |
| [TICKET-003](TICKET-003-tests-docs-and-release.md) | 測試、文件、相容性驗證與交付 | TICKET-001、002 | ✅ 完成 |

## 驗證紀錄

- `SpeechTranscriber.isAvailable == true`（本機 macOS 27 測試環境）。
- `SpeechTranscriber.supportedLocales` 與 `installedLocales` 均包含精確 `zh_TW`。
- 使用 8.74 秒中英混合合成音訊成功取得新 API final result。
- Release build、Speech backend policy tests、AudioTap format tests、AudioInput availability tests 全部通過。

## 後續非本輪範圍

- 使用 `AnalyzerInput` 將錄音 buffer 直接串流到 `SpeechAnalyzer`，取代 legacy live preview。
- Breeze 8-bit／6-bit／hybrid 量化。
- 台灣中英混用真實語料 benchmark 與自動 regression gate。
- WAV writer completion、paste coordinator 與 Python model lifecycle 重構。
