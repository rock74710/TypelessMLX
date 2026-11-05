# 驗證紀錄

- 集中驗證通過。本機模型載入與套件簽章通過。
- 按住模式新增回歸先失敗，再通過。實機與語料品質未驗證。

## 集中腳本

2026-11-05 13:36，主代理執行 `bash scripts/test-upgrade.sh`。
首次執行退出 133：ModelReadiness 測試因 Python 驗證器缺少 `sys` 匯入失敗。
加入匯入後，第二次執行退出 0。受審來源為 de9644e。

通過：release build；AudioTapFormat、AudioInputAvailability、HotkeySupport、SpeechBackendPolicy、Workflow、GainAndText 六個可執行目標；Bridge 傳輸整合；ModelReadiness Swift/Python 合約；十五個 Python unittest。

編譯仍有既有 CFString 指標警告。未將此警告算成已修復。

## 本機模型

主代理使用既有 venv 執行 `backend/transcribe_server.py --prepare-model breeze-asr-25`，退出 0。
回傳 ready，來源 local-8bit，revision local:breeze-8bit:6e48985d562fcf19e80daf8bebf84fb994fb3cc7，大小 1644566459 bytes。
此步重用就緒標記，不代表重新載入。

主代理另呼叫 `transcribe_server._load_whisper`，使用同一個本機 8-bit 目錄。
程序退出 0，輸出 `Local Breeze 8-bit loader: PASS`。
沒有下載新模型，也沒有執行語音品質評測。

## 套件

主代理執行 `bash build-app.sh`，退出 0。
產生 `build/TypelessMLX.app` 與 `build/TypelessMLX-1.0.3.dmg`。
使用現有 Apple Development 憑證簽署，`codesign --verify --deep --strict` 通過。
此套件對應 de9644e；按住模式修正完成後需重新建置。

## 限制

尚無常用 App 的完整 AX 與系統貼上驗收、內外接麥克風及休眠／拔除驗收、六十段繁中與混語品質評測。
自有 NSTextView 與獨立剪貼簿測試不能取代這些驗收。
裝置中斷時，尚未交給協調器的部分錄音不提供救援；本輪救援限辨識失敗。

## 按住模式修正

coding 代理先執行新增 HotkeySupport 測試，得到預期失敗：release during preparation should cancel it。
修正後，代理執行 HotkeySupport 與 release build 通過。
主代理讀取實際差異，並執行 release HotkeySupport 目標，退出 0。
此修正只增加準備／錄音期間的放開事件處理；其餘集中測試證據沿用 de9644e。
