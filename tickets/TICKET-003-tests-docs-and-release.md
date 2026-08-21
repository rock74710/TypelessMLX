# TICKET-003：測試、文件與交付驗證

**狀態：✅ 完成**

## 目標

為 modern/legacy backend 選擇建立可離線測試的純邏輯層，並更新使用者與開發文件。

## 範圍

- 抽出可測試的 locale 精確比對、contextual glossary 正規化與 backend decision 純函式。
- 新增 executable test target，至少覆蓋：
  - `zh-TW` 精確命中。
  - `zh-CN`／`zh-HK` 不得被當成 `zh-TW`。
  - modern unavailable 時回退 legacy。
  - glossary 去空白、去重、數量與單詞長度限制。
- README 更新：快速／高精度雙模式、macOS 版本需求、runtime locale fallback。
- CHANGELOG 加入本次升級說明。
- 執行 release build 與所有現有／新增測試，記錄結果。

## 驗收

- 測試不需要麥克風、Speech asset 或網路即可執行。
- README 不再把 legacy `SFSpeechRecognizer` 描述成唯一 macOS backend。
- 不改寫與本功能無關的歷史或使用者檔案。

## 檔案所有權

- `TypelessMLX/SpeechBackendPolicy/SpeechBackendPolicy.swift`（新增；與 TICKET-001 協調介面）
- `TypelessMLX/Tests/SpeechBackendPolicy/main.swift`（新增）
- `Package.swift`
- `README.md`
- `CHANGELOG.md`
