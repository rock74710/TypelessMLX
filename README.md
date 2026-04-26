# TypelessMLX

**macOS 語音聽寫 App** — 按住快捷鍵說話，文字自動打入當前視窗。  
使用 [MLX Whisper](https://github.com/ml-explore/mlx-examples) 在 Apple Silicon 上做完全離線推理，預設使用 mac 語音辨識，設定中有採用台灣中文優化的 [Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) 模型。

>會設計的原因是市面上常見的產品都是使用Whisper ，而我將目前台灣中文友善的breeze 且轉成MLX格式後做為主力引擎，使用且配合 Apple Intelligence做輕度修正。大概能做速度最佳化都弄上去．

---

## 功能特色

- 🎙️ **一鍵聽寫**：按可自訂快捷鍵開始/停止錄音，自動貼入游標位置
- 🇹🇼 **台灣中文優化**：使用Mac 語音辨識，可選擇 Breeze-ASR-25 模型，繁體中文效果最佳
- ✏️ **自動標點符號**：語音辨識後自動補上逗號、句號、問號等標點
- 🤖 **AI 文字修正**（選用）：macOS 26+ 可啟用 Apple Intelligence 進一步精煉標點與語句
- 🔌 **完全離線**：所有推理在本機完成，無任何資料上傳
- 🎛️ **多模型支援**：
  - Breeze-ASR-25（台灣中文，預設）
  - Qwen3-ASR-0.6B（中文精度最佳，推薦）
  - Whisper Large v3 / Medium / Small（多語言）
  - macOS 內建語音辨識（無需 Python）
- 🗑️ **語助詞過濾**（選用）：自動移除「呃」「嗯」等猶豫音
- 📋 **聽寫歷史**：保留最近 N 筆紀錄，可一鍵複製
- 🌙 **系統選單列 App**：輕量常駐，不佔 Dock

---

## 系統需求

| 項目 | 最低需求 |
|------|---------|
| macOS | 13.0 Ventura（建議 macOS 26+ 以使用 AI 文字修正） |
| 硬體 | Apple Silicon（M1 或以上，fp16 加速） |
| 磁碟 | ~500 MB（Python venv） + 模型大小（見下表） |
| Python | 由 App 自動安裝，無需手動設定 |

### 模型大小參考

| 模型 | 大小 | 說明 |
|------|------|------|
| macOS 內建 | 0 MB | **預設**，免下載，立即可用 |
| Qwen3-ASR-0.6B | ~1 GB | 直接從 HuggingFace 下載，中文精度最佳 |
| Breeze-ASR-25 | ~1.8 GB | 直接從 HuggingFace 下載，台灣中文優化 |
| Whisper Large v3 | ~3.1 GB | 多語言最高精度 |
| Whisper Medium | ~1.5 GB | 多語言中等 |
| Whisper Small | ~465 MB | 多語言最快 |

---

## 快速開始

### 方法一：下載 DMG（最簡單）

前往 [Releases](../../releases) 下載最新的 `.dmg`，拖入 `/Applications`。

首次啟動後在設定視窗點「**開始安裝**」，程式會自動：
1. 建立 Python venv
2. 安裝 mlx-whisper 等相依套件（約 1–2 分鐘）

預設使用 macOS 內建語音辨識，**無需下載任何模型即可立即使用**。
如需更高精度，可在設定中切換至 Qwen3-ASR 或 Breeze-ASR-25，首次選用時會自動從 HuggingFace 下載。

### 方法二：從原始碼編譯

```bash
# 1. Clone
git clone https://github.com/YOUR_USERNAME/TypelessMLX.git
cd TypelessMLX

# 2. 設定固定的 Apple code-signing identity
security find-identity -v -p codesigning
export SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"

# 3. 建立 app bundle 並安裝到 /Applications
./build-app.sh --install
```

> **注意**：需要 Xcode Command Line Tools（`xcode-select --install`）及 macOS 26 SDK（如需編譯 AI 文字修正功能）

> **開發簽章**：Accessibility / Input Monitoring 授權會跟著 app 的 code-signing requirement。請使用固定的 `SIGN_IDENTITY` 並固定從 `/Applications/TypelessMLX.app` 啟動，重 build 後授權才會穩定保留。沒有 signing identity 時，`build-app.sh` 會停止；臨時測試可用 `ALLOW_ADHOC_SIGNING=1 ./build-app.sh --install`，但 ad-hoc build 可能每次重 build 都需要重新授權。

---

## 使用方式

1. 啟動後選單列出現麥克風圖示
2. 在任何輸入框游標點一下（讓視窗取得焦點）
3. **按住設定中的辨識快捷鍵** → 說話 → **放開**，文字自動打入

> 可在設定中切換為「切換模式」（按一下開始，再按一下停止）

### 權限需求

首次啟動需授權以下項目：

| 權限 | 用途 |
|------|------|
| 🎙️ 麥克風 | 錄製語音 |
| ♿ 輔助使用 | 模擬 Cmd+V 貼入文字 |
| ⌨️ 輸入監控 | 偵測全域辨識快捷鍵 |

---

## 架構說明

```
按辨識快捷鍵
    └─ HotkeyManager (CGEvent/NSEvent flagsChanged)
        └─ AudioRecorder (AVAudioEngine, WAV)
            └─ WhisperBridge (stdin/stdout JSON-RPC)
                └─ transcribe_server.py
                    └─ mlx_whisper / mlx_audio (本機推理)
                └─ TextRefiner (Apple Intelligence, 選用)
            └─ TextPaster (NSPasteboard + CGEvent Cmd+V)
```

### 專案結構

```
TypelessMLX/
  Sources/
    TypelessMLXApp.swift        # @main, AppDelegate, 選單列 App
    AppState.swift              # 狀態管理, 設定持久化
    HotkeyManager.swift         # 快捷鍵監聽
    AudioRecorder.swift         # AVAudioEngine 錄音
    WhisperBridge.swift         # Python subprocess JSON-RPC
    TextPaster.swift            # 剪貼簿 + CGEvent 貼文
    TextRefiner.swift           # Apple Intelligence 文字修正
    RecordingOverlay.swift      # 浮動錄音指示面板
    StatusBarController.swift   # 選單列圖示
    SettingsView.swift          # 偏好設定視窗
    SetupWindowController.swift # 首次安裝流程
    Logger.swift                # 日誌 (~/Library/Logs/TypelessMLX/)

backend/
  transcribe_server.py          # 持久化 JSON-RPC Python server
  convert.py                    # Whisper → MLX 格式轉換
  requirements.txt              # mlx-whisper, mlx-audio, numpy, soundfile
```

---

## 設定選項

| 選項 | 說明 |
|------|------|
| 模型 | 選擇語音辨識模型 |
| 語言 | 自動偵測 / 指定語言代碼（如 `zh`、`en`） |
| 辨識快捷鍵 | 選擇用來開始/停止錄音的 modifier key |
| 快捷鍵模式 | 按住模式 / 切換模式 |
| 浮動指示器 | 錄音時顯示/隱藏底部面板 |
| 文字修正 | 啟用 Apple Intelligence 標點修正（需 macOS 26+） |
| 語助詞過濾 | 自動移除「呃」「嗯」等猶豫音 |
| 隨系統啟動 | 登入時自動啟動 |

---

## 偵錯 / 日誌

日誌儲存於 `~/Library/Logs/TypelessMLX/`，可用以下指令查看：

```bash
tail -f ~/Library/Logs/TypelessMLX/typelessmlx.log
```

---

## 常見問題

**Q: 第一次錄音很慢？**  
A: 首次使用需載入模型（1–5 秒），之後維持常駐速度很快。

**Q: macOS 要求存取 Photos / Apple Music？**  
A: 這是 macOS 26 啟用 Apple Intelligence 時的系統提示，**可以拒絕**，不影響聽寫功能。App 本身不存取任何個人資料。

**Q: 文字貼入後多了空格？**  
A: 在英文輸入法下剪貼簿可能自動加空格，可切換至中文輸入法後再試。

**Q: Breeze-ASR-25 或 Qwen3-ASR 下載失敗？**  
A: 請確認網路連線正常。這兩個模型都是公開的 HuggingFace repo，無需帳號或 Token。若持續失敗可嘗試手動執行：`hf download schsu/breeze-asr-25-mlx`。

**Q: 下載後出現「無法驗證開發者」或「可能有害」警告？**

A: 這是 macOS Gatekeeper 對未公證 app 的標準提示。在終端機執行以下指令移除隔離屬性即可正常開啟：

```bash
xattr -rd com.apple.quarantine /Applications/TypelessMLX.app
```

或右鍵點 app → 選「打開」→ 再點「打開」確認。之後就不會再出現此警告。

---

**Q: 為什麼每次從原始碼重 build 都要重新授權 Accessibility / Input Monitoring？**

A: 如果 app 是 ad-hoc signed，macOS 會用每次 build 不同的 code hash 辨識它。請改用固定的 Apple Development 或 Developer ID identity 簽署，並固定安裝到 `/Applications/TypelessMLX.app` 後啟動。

---

## License

[MIT License](LICENSE)

---

## 致謝

- [MediaTek Research](https://huggingface.co/MediaTek-Research) — Breeze-ASR-25 模型
- [ml-explore/mlx-examples](https://github.com/ml-explore/mlx-examples) — MLX Whisper
- [lucasnewman/mlx-audio](https://github.com/lucasnewman/mlx-audio) — Qwen3-ASR 支援
