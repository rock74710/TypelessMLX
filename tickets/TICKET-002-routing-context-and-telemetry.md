# TICKET-002：路由、Context 與 Telemetry

**狀態：✅ 完成**

## 目標

讓快速模式的產品文案、字典 context 與效能 log 對應新的 Apple backend，同時維持 Breeze 高精度模式。

## 範圍

- 將 `macos-speech` 文案更新為「macOS 新語音辨識（26+）／相容模式」。
- `SpeechStreamer.transcribe` 傳入使用者字典 contextual strings；最多 40 個詞，每詞限制合理長度並去重。
- 新增 backend 狀態／實際 backend 名稱供 log 與 UI 顯示，但不把 runtime 不支援誤判為整個 App 權限失敗。
- 記錄 routing start、modern/legacy backend、fallback reason、final latency。
- 保持 Breeze 的 model routing 完整不變。
- 修正文案：Apple 快速、Breeze 台灣中英高精度；不宣稱 Apple 一定支援所有 `zh-TW` 裝置。

## 驗收

- 選擇 `macos-speech` 時由 `SpeechStreamer` 自動決定 modern／legacy。
- Breeze、Qwen 與 Whisper 模型仍走 Python backend。
- 字典內容會傳入 modern backend，空字典不產生多餘 context。
- 設定頁清楚顯示 OS 條件與 fallback 行為。
- Release build 通過。

## 檔案所有權

- `TypelessMLX/Sources/AppState.swift`
- `TypelessMLX/Sources/HotkeyManager.swift`
- `TypelessMLX/Sources/SettingsView.swift`
- `TypelessMLX/Sources/StatusBarController.swift`（如確有需要）
