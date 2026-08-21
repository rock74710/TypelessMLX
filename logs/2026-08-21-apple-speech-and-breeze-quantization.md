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
- 已完成兩位 ASCEND 說話者的方向性 Breeze 量化比較，但尚未進行台灣真人、不同麥克風與背景噪音的產品品質比較。
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

## 本機量化實測結果

### 環境與方法

- Mac：M4 Pro、24 GB unified memory。
- Runtime：macOS 27.0 arm64、Python 3.12.11、`mlx-whisper 0.4.3`、MLX `0.31.1`。
- 所有模型使用相同參數：固定 `language="zh"`、`temperature=0.0`、`without_timestamps=true`、相同 bilingual prompt。
- 每個模型使用 fresh subprocess，模型之間嚴格依序執行。
- 每個音檔先 warm-up，再計時 3 次 hot inference。
- Peak MLX memory 包含 model load、cold inference、warm-up 與 hot runs。

建立的 artifact：

| 模式 | 量化方式 | Weights |
|---|---|---:|
| FP16 | 原始 Breeze | 2.871 GiB |
| 8-bit | 所有 Linear／Embedding，affine group-64 | 1.532 GiB |
| 6-bit | 所有 Linear／Embedding，affine group-64 | 1.174 GiB |
| Hybrid | 只量化 encoder Linear 為 6-bit | 2.175 GiB |
| 4-bit | BRlin artifact，affine group-64 | 0.817 GiB |

### 合成中英語音方向性結果

五段 macOS `say` Meijia 合成音訊、共 15 次 hot run。此組只適合速度、記憶體與 regression 檢查，不是人類語音 accuracy evidence。

| 模型 | Hot median | Hot p95 | Peak MLX | 空白 | 與 FP16 不同 |
|---|---:|---:|---:|---:|---:|
| FP16 | 0.769s | 1.056s | 3.673 GiB | 0/15 | 0/15 |
| 8-bit | 0.726s | 0.956s | 2.346 GiB | 0/15 | 0/15 |
| 6-bit | 0.728s | 0.949s | 1.988 GiB | 0/15 | 0/15 |
| Hybrid | 0.784s | 1.072s | 2.982 GiB | 0/15 | 0/15 |
| 4-bit | 0.690s | 0.889s | 1.631 GiB | 0/15 | 9/15，分布於 3/5 句型 |

完整結果：[synthetic summary](../benchmarks/breeze_quant/results/summary.md)。

### 真人 ASCEND mixed subset

使用官方 `CAiRE/ASCEND` test split revision `737e9800ae31be9932ba8464c80366559bd28424` 的 17 段真人 mixed utterances，共 77.95 秒：8 段中文開頭、9 段英文開頭、兩位說話者。資料授權為 CC BY-SA 4.0。這是 bounded directional subset，不是完整 ASCEND，也不是台灣口音產品語料。

| 模型 | Hot median | Hot p95 | Peak MLX | Mixed error | 空白 | 不同於 FP16 的句子 |
|---|---:|---:|---:|---:|---:|---:|
| FP16 | 0.713s | 0.913s | 3.680 GiB | 34.93% | 0/51 | 0/17 |
| 8-bit | 0.723s | 0.869s | 2.352 GiB | 35.29% | 0/51 | 1/17 |
| 6-bit | 0.703s | 0.845s | 1.995 GiB | 35.66% | 0/51 | 1/17 |
| Hybrid | 0.784s | 0.954s | 2.988 GiB | 34.93% | 0/51 | 0/17 |
| 4-bit | 0.699s | 0.833s | 1.638 GiB | 36.03% | 0/51 | 9/17 |

主 mixed error 使用 NFKC 正規化後的中日韓單字元、英文詞與連續數字 token Levenshtein；忽略標點與英文大小寫。大小寫敏感與標點結果另存於完整 JSON。

完整結果：[ASCEND real-speech summary](../benchmarks/breeze_quant/results/ascend_real_summary.md)。

### 實測判讀

- **FP16**：仍應是高精度基準。Peak 約 3.68 GiB。
- **8-bit**：目前最合理的平衡模式。Peak memory 減少約 36%，mixed error 只增加 0.36 個百分點；median 沒有明顯加速，但 p95 約快 4.8%。
- **6-bit**：Peak memory 減少約 46%，p95 約快 7.4%，但 mixed error 增加 0.73 個百分點，超過原先 0.5 pp gate；較適合「平衡－省記憶體」次選項。
- **Hybrid encoder-only**：文字和 FP16 完全相同，但 memory 只省約 19%，median 約慢 10%；目前 predicate 不值得作產品模式。
- **4-bit**：Peak memory 減少約 55%，p95 約快 8.8%，但 mixed error 增加 1.10 個百分點，17 段中有 9 段文字改變。適合低記憶體模式，不適合取代 FP16。
- 這個 17 段 subset 所有模型都沒有空白輸出；不能推翻第三方完整 1,315 短句測試中 4-bit 空白輸出增加的結果。

## 建議產品模式

- **快速模式**：Apple 新 Speech API。
- **台灣中英高精度**：Breeze FP16。
- **Breeze 平衡模式**：優先 8-bit；6-bit 可作更省記憶體的次選項。
- **低記憶體模式**：4-bit，清楚標示短句漏字風險。

目前不建議直接把 Breeze FP16 全面替換成 4-bit。若要先推出一個平衡模式，這輪實測支持從 8-bit 開始；正式上線前仍需使用台灣真人與產品麥克風語料完成 gate。

## Breeze 8-bit 正式預設（TypelessMLX）

已將 App 與 Python backend 的 Breeze 解析順序統一為：

1. `~/.local/share/typelessmlx/models/breeze-asr-25-mlx-8bit`（canonical affine 8-bit，group size 64）。
2. `~/.local/share/typelessmlx/models/breeze-asr-25-mlx`（既有 FP16 相容路徑）。
3. `schsu/breeze-asr-25-mlx`（既有 HF repo；不假設尚未發布的 8-bit repo）。

`selectedModelID` 保持 `breeze-asr-25` 不變，因此既有設定不需 migration；若 8-bit artifact 缺少，AppState 與 backend 都會記錄明確 fallback log，不會讓既有 FP16 使用者無提示失效。大型量化權重不提交到 repository；可用 `benchmarks/breeze_quant/quantize_models.py` 從 canonical FP16 來源重現。

`ModelManager` 的快取大小與刪除目標也使用相同解析順序，避免畫面顯示 HF／FP16 快取大小，但實際推論載入本機 8-bit artifact。Python 啟動訊息將 `fp16` 明確標為非量化運算的 compute dtype；每次 Breeze 解析則另行記錄實際 artifact 路徑。
