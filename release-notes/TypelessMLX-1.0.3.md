# TypelessMLX 1.0.3 Release Notes

發行日期：2026-08-21
Build：4

## 重點更新

### 可自訂聽寫快捷鍵

- 在「偏好設定 → 一般 → 快捷鍵」點擊「錄製快捷鍵」即可更換。
- 支援 Left／Right Option、Command、Control 與 Shift。
- 新快捷鍵立即生效，重新啟動 App 後仍會保留。
- 錄製期間按 Escape 可取消；Caps Lock、一般按鍵與未知按鍵不會覆蓋原設定。
- 「切換模式」與「按住模式」均支援所有可選快捷鍵。
- 預設快捷鍵仍為 Right Option。

### 語音辨識與效能

- macOS 26+ 在精確語系與 Speech asset 可用時，優先使用新的 `SpeechAnalyzer`／`SpeechTranscriber`；不支援時自動回退相容模式。
- 保留 Breeze-ASR-25 台灣中英高精度模式，並優先使用本機 8-bit artifact。
- 新增自動標點與可選的 Apple Intelligence 文字修正。
- 閒置 15 分鐘後會釋放 AI 模型，下次聽寫時自動重新載入。

## 安裝

1. 開啟 `TypelessMLX-1.0.3.dmg`。
2. 將 `TypelessMLX.app` 拖入「應用程式」。
3. 首次啟動時依提示授權麥克風、輔助使用與輸入監控。
4. 如使用 Breeze、Qwen 或 Whisper 模型，請在設定流程中安裝 Python 後端與模型。

## 系統需求

- macOS 13 或更新版本。
- Apple Silicon Mac（MLX 模型路徑）。
- macOS 26+ 才能使用新的 Apple Speech API 與 Apple Intelligence 文字修正；較舊系統會使用相容模式。

## 已知限制

- 本次本機產物使用 ad-hoc 簽章且未 notarize，適合內部測試；公開散佈前仍需使用 Developer ID 簽章並完成 Apple notarization。
- macOS 可能在 App 重建或替換後要求重新授權輔助使用或輸入監控。
- 本版僅支援單一修飾鍵，不支援 Command+Shift+Space 等多鍵組合或快捷鍵衝突偵測。
