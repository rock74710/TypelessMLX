# 2026-08-21：Apple Speech 升級與 Breeze 低精度評估

## 本次目標

將 macOS 26+ 新 Speech API 納入 TypelessMLX 快速模式，同時保留 Breeze-ASR-25 作為台灣華語與英文混用的高精度引擎；另外評估 Breeze 是否能透過低精度權重降低延遲與記憶體用量。

## Git 紀錄

- Branch：`feat/apple-speech-transcriber`
- `745e020 docs: plan Apple Speech API migration tickets`
- `f0d5c1f feat: add modern Apple speech transcription backend`

原本未追蹤的 `AGENTS.md` 與 `scripts/` 未納入 commit。

## 已完成修改

### Apple Speech final backend

- macOS 26+ 優先使用 `SpeechAnalyzer` + `SpeechTranscriber`。
- runtime 檢查 `SpeechTranscriber.isAvailable`。
- 僅接受精確 locale：`zh-TW`、`en-US`、`ja-JP`、`ko-KR`。
- 檢查 supported／installed locales 與 Speech asset 狀態。
- 缺少 asset 時嘗試透過 `AssetInventory` 安裝。
- modern backend 不可用、asset 或推論失敗、回傳空文字時，自動回退 legacy `SFSpeechRecognizer`。
- 使用 generation ID 與 completion gate，防止取消、fallback 或 late callback 造成重複貼上。
- 使用者詞典正規化後作為 contextual strings；最多 40 詞，每詞最多 80 字。
- log 記錄 backend、locale、fallback reason、routing latency 與 key-up-to-final latency。

### App 與文件

- macOS 原生模型文案更新為「macOS 新語音辨識（26+）／相容模式」。
- 原生模式不再把 Python backend 視為必要條件。
- Breeze、Qwen 與其他 Whisper 模型仍使用既有 Python／MLX 路徑。
- README 改成「本機優先」：macOS 26+ 新 API 與 MLX 在本機推理；舊系統相容模式由 Apple Speech 服務決定是否需要連線。
- Breeze 權重大小由錯誤的約 1.8 GB 修正為目前 artifact 實際約 2.9 GB。

## 驗證結果

- `swift build -c release`：通過。
- `TypelessMLXSpeechBackendPolicyTests`：通過。
- `TypelessMLXAudioTapFormatTests`：通過。
- `TypelessMLXAudioInputAvailabilityTests`：通過。
- 本機 `SpeechTranscriber.isAvailable == true`。
- 本機 supported 與 installed locales 均包含精確 `zh_TW`。
- 使用 8.74 秒中英混合合成音訊成功取得 Apple 新 API final result。

完整 build 需使用已安裝 Xcode 工具鏈：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build -c release
```

目前 `xcode-select` 指向獨立 Command Line Tools；其 SwiftUI SDK 缺少 `SwiftUIMacros` plugin，因此直接執行 `swift build` 會失敗。這是工具鏈問題，不是本次程式碼錯誤。

## 尚未完成

- Live preview 仍使用 legacy `SFSpeechRecognizer`。
- 尚未把錄音中的 PCM buffer 轉成 `AnalyzerInput` 串流給新 API。
- 尚未進行多位真人、不同口音與不同背景噪音的 Apple／Breeze 品質比較。
- 既有 `AudioRecorder.swift` 仍有 CoreAudio `CFString` pointer compiler warnings。

## Breeze 低精度是否可行？

可行。現在的 Breeze MLX 權重是 FP16、約 2.9 GB；`mlx-whisper` loader 能載入帶有 quantization metadata 的模型，MLX 也支援 2、3、4、5、6、8-bit affine quantization。專案目前的 `backend/convert.py` 只提供 FP16／FP32，因此若要產生低精度 Breeze，需要擴充 converter 或採用官方 MLX Whisper quantized conversion 流程。

### 已知證據

第三方 [BRlin/Breeze-ASR-25-mlx-4bit](https://huggingface.co/BRlin/Breeze-ASR-25-mlx-4bit) artifact 使用 affine 4-bit、group size 64，部分層保留 FP16。其 M4 Pro 測量結果：

| 項目 | FP16 | 4-bit |
|---|---:|---:|
| 300 秒長音訊 median RTF | 0.0795 | 0.0563 |
| Peak memory | 3.99 GB | 1.80 GB |
| ASCEND mixed error | 17.97 | 19.26 |
| 1,315 個短句空白結果 | 35 | 77 |

換句話說，4-bit 在該長音訊測試約有 1.4 倍 throughput、記憶體約減半，但短句空白率與中英混用錯誤都明顯惡化。這些是該 artifact 作者的測量，不是 MediaTek 或 Apple 官方 benchmark，也不能直接視為 TypelessMLX 的產品結果。

### 建議實驗順序

1. **FP16 baseline**：保留目前品質模式。
2. **8-bit**：最可能維持接近 FP16 品質，先確認是否真的有 latency／memory 收益。
3. **6-bit**：在 8-bit 收益太小時測試。
4. **Hybrid quantization**：優先量化 encoder／MLP，保留 decoder、token embedding 或首尾關鍵層 FP16。
5. **4-bit**：只作「快速／低記憶體模式」，不可未經產品語料驗證便取代 FP16。

### 需要量測的設定

- `language=None` 與固定 `language="zh"`。
- `temperature=0.0`、`(0.0, 0.2)` 與目前六段 fallback。
- `without_timestamps=True/False`。
- FP16、8-bit、6-bit、hybrid、4-bit。
- Cold start、warm p50／p95、key-up-to-paste、RTF、peak memory 與 energy impact。

### 品質資料

至少建立 200–500 段同意使用的真實聽寫語料，涵蓋：

- 台灣華語。
- 純英文。
- 中文開頭的中英混用。
- 英文開頭的中英混用。
- API、產品名、縮寫、網址、數字與日期。
- 1–3 秒短句、3–8 秒一般聽寫、8–30 秒長句。
- 安靜環境、鍵盤聲、風扇聲與完全靜音。

### 建議上線門檻

- Warm key-up-to-paste p95 至少改善 20%。
- Mixed error 增幅不超過 0.5 個百分點。
- 空白結果率不得高於 FP16。
- 技術詞 exact recall 降幅不超過 1 個百分點。
- 繁體中文輸出率與數字／英文大小寫不得明顯退化。

## 建議產品模式

- **快速模式**：Apple 新 Speech API。
- **台灣中英高精度**：Breeze FP16。
- **Breeze 平衡模式**：通過驗證後採 8-bit／6-bit 或 hybrid。
- **低記憶體模式**：4-bit，清楚標示短句漏字風險。

目前不建議直接把 Breeze FP16 全面替換成 4-bit；最值得先做的是建立可重現 benchmark，接著產生 8-bit 與 6-bit artifact，找出品質與延遲的 Pareto 最佳點。
