2026-11-05 13:43:48 +0800 | gpt-6.1-sol / low

Reviewed implementation commit: e14a1c3be57e436c8f5b1e5bbc43d3c15e17dd88

- **結果：通過。** 準備期間放開快捷鍵會取消任務。晚到結果不能啟動錄音。初審 F-1 已解除。

- **限制：** 實機麥克風、常用 App 與六十段品質語料仍未驗證。不得宣稱辨識品質改善。

- **下一步：** 協調者可完成交付紀錄。封裝的 DMG 尚待完成，不視為本報告已驗證項目。

Outcome: PASS

Minimality: PASS

Conformance: PASS

Verdict: PASS

## 修正驗收

- **F-1 已解除。** `TypelessMLX/Sources/HotkeyManager.swift:137` 在準備期間收到放開事件，會呼叫 `cancelCurrentTask`。取消先使 UUID 失效，再停止後端與清理狀態。

- **舊回呼不能改變新任務。** `HotkeyManager.swift:218` 先檢查原任務 UUID，再更新按住狀態。因此，舊準備結果不能將新任務提早轉成錄音。原有 `prepareBackend` 回呼也保留 UUID 檢查。

- **按住模式正常結束。** `TypelessMLX/HotkeySupport/HoldHotkeyState.swift:28` 只允許準備中的任務開始錄音。準備時放開會取消；錄音時放開會停止錄音並辨識。重複放開沒有作用。完成、失敗及取消都經既有重設路徑清除狀態。

- **切換模式的操作保留。** Toggle 分支沒有改動，仍由按下事件開始或停止。一般按住分支仍由放開事件停止。測試直接覆蓋按住狀態；跨模式的即時切換以程式檢查確認，未執行實機事件測試。

- **測試足以支持此修正。** `TypelessMLX/Tests/HotkeySupport/main.swift:101` 覆蓋準備時放開、晚到完成被忽略、重複放開，以及下一次正常錄音。沿用工作者先失敗再通過、協調者 release HotkeySupport 通過，以及 release build 通過的證據。未重跑全套測試。

## 最小性與範圍

- 獨立嘗試移除新 helper，只用 `isPreparingModel` 判斷。這個旗標在模型準備完成後就會清除，但 Python 啟動仍可能等待。單用此旗標會漏掉另一段準備時間。

- 也可在協調器加入另一個旗標，但仍需記錄準備、錄音及取消的轉換。現有五十行 helper 沒有依賴，並可直接測試。保留它比重複分散條件更清楚，沒有不必要的架構改動。

- 此次產品差異只有 `HotkeyManager`、`HoldHotkeyState` 與快捷鍵測試。其他差異為審查及驗證紀錄。變更修正本輪準備流程的缺陷，沒有擴大 A–E 授權範圍。

## 完整驗收的承接

- 沿用 [初審報告](acceptance-report.md) 對 R-1–R-5 及 INV-1–INV-6 的安全與功能檢查。此次差異不改剪貼簿、救援儲存、模型驗證、增益或文字替換。

- R-1／INV-1：目標、安全輸入、剪貼簿版本與所有權檢查仍成立。R-2／INV-2：UUID 隔離與取消檢查保留，並修正準備期間放開操作。

- R-2／INV-3：私有救援目錄、保存上限、成功及取消刪除仍成立。R-3／INV-4：固定來源、必要檔案、雜湊、就緒標記與修復保護仍成立。

- R-4／INV-5：增益仍只在分流前套用一次。R-5／INV-6：人工確認、最長符合、單次替換及不安全整理回退仍成立。

- 既有完整證據包括 release build、六個 Swift 可執行目標、Bridge、ModelReadiness、十五個 Python 測試，以及本機 Breeze 8-bit 準備與實際載入通過。此次沿用未變更部分的證據。

- 協調者另回報此次 `build-app.sh` 編譯與簽署通過。DMG 製作仍在完成中，本報告沒有將它算成通過。

- 初審記錄的裝置中斷部分錄音救援仍屬提案。實機與品質資料限制保持明列，不新增未授權行為。

Self-check: 已核對完整提交、窄差異、F-1、舊 UUID 回呼、模式行為、最小性及完整驗收承接；未改產品或初審報告，未重跑全套測試。
