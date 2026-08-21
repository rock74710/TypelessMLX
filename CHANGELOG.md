# Changelog

## [Unreleased]

### 新增
- **macOS 原生語音辨識雙模式**：macOS 26+ 在精確 locale、系統能力與 Speech asset 都符合時優先使用 `SpeechAnalyzer`／`SpeechTranscriber`；不支援時自動回退 `SFSpeechRecognizer` 相容模式
- **快速／高精度路由說明**：原生 macOS 語音辨識維持快速免模型模式，Breeze-ASR-25 維持台灣中英高精度 MLX 模式；Breeze、Qwen 與 Whisper 路徑不變
- **離線 backend policy 測試**：加入精確 BCP-47 locale 比對、contextual glossary 正規化與 modern/legacy fallback 的 executable tests
- **自動標點符號**：語音辨識結果現在會自動加上逗號、句號、問號等標點符號
  - Whisper 模型透過 initial prompt 引導輸出帶標點文字
  - macOS 26+ 可啟用「文字修正」進一步精煉標點（設定 > 文字修正）
- **待機節能**：App 閒置 15 分鐘後自動關閉 AI 模型，節省 GPU/ANE 記憶體
  - 下次使用快捷鍵時自動重新載入（約 5-10 秒）
  - 載入期間 overlay 顯示「⏳ 載入模型中...」

### 改善
- **Breeze 預設 artifact**：Breeze 維持 `breeze-asr-25` model ID，優先使用本機 affine 8-bit artifact（group size 64）；缺少時依序回退既有 FP16 local artifact 與 `schsu/breeze-asr-25-mlx` HF repo，既有使用者不需重新下載。
- 文字修正（TextRefiner）預設開啟（需 macOS 26+）
- 若 Whisper 已輸出帶標點文字，自動跳過 TextRefiner 以節省時間
