# TICKET-004：可自訂聽寫快捷鍵

**狀態：✅ 完成**

## 目標

讓使用者能在「偏好設定 → 一般 → 快捷鍵」直接錄製並儲存聽寫快捷鍵，不再固定使用 Right Option；修改後應立即生效，重新啟動 App 後仍保留。

## 背景

- `AppState.hotkeyKeyCode` 已使用 `@AppStorage` 持久化，但目前設定頁只顯示名稱，沒有修改入口。
- `HotkeyManager.handleFlagsChanged` 把按下狀態寫死為 `.option`；即使 key code 改成 Command、Control 或 Shift，也無法正確觸發。
- 選單列提示目前寫死為 `Right ⌥ Option`。

## 範圍

- 在設定頁提供清楚的「錄製快捷鍵」操作：
  - 點擊後進入等待輸入狀態，下一個受支援的單一修飾鍵成為新快捷鍵。
  - 支援左右側的 Option、Command、Control、Shift，並在 UI 中清楚顯示左右側與符號。
  - Escape 取消錄製，不覆蓋原設定。
  - 不接受一般字母、數字、Caps Lock 或不明 key code；顯示簡短原因並保留原設定。
- 將 key code、對應 modifier flag、顯示名稱與支援判斷集中成單一可測試的純邏輯來源，避免設定頁、監聽器與選單各自維護對照表。
- `HotkeyManager` 依目前選定快捷鍵的 modifier flag 判斷 key-down/key-up，維持既有兩種模式：
  - `toggle`：每次 key-down 切換開始／停止。
  - `hold`：key-down 開始、key-up 停止。
- 快捷鍵變更後立即生效，不需要重啟或重建 event monitor。
- 選單列提示使用目前快捷鍵的顯示名稱，不得再寫死 Right Option。
- 保留既有 `hotkeyKeyCode = 61` 的預設值及既有使用者設定相容性；遇到無效的舊值時安全回退 Right Option。
- 更新 README 中寫死 Right Option 的使用說明，說明預設值與自訂方式。

## 非範圍

- 多鍵組合（例如 Command+Shift+Space）。
- 一般按鍵或功能鍵作為單鍵快捷鍵。
- 與其他 App 的快捷鍵衝突偵測。
- 改用 Carbon RegisterEventHotKey 或第三方 hotkey 套件。

## 驗收標準

- 新安裝預設仍為 Right Option。
- 使用者可依序改成 Left Option、左右 Command、左右 Control、左右 Shift，實際聽寫觸發與 UI 顯示一致。
- `toggle` 與 `hold` 模式在所有支援快捷鍵上都能正確處理按下／放開，單次按鍵不會重複觸發。
- 錄製期間按 Escape 或輸入不支援按鍵，不會破壞目前設定。
- 修改後立即生效，關閉並重新開啟 App 後設定仍存在。
- 選單列與偏好設定顯示相同快捷鍵名稱。
- 純邏輯測試至少覆蓋：所有支援 key code 的 flag/name mapping、無效 key code 回退，以及 key-down/key-up 判定。
- `swift build -c release` 與所有既有／新增 executable tests 通過。
- 不覆寫或回復與本 ticket 無關的既有工作區變更。

## 建議檔案所有權

- `TypelessMLX/HotkeySupport/HotkeyDefinition.swift`（新增純邏輯模組）
- `TypelessMLX/Tests/HotkeySupport/main.swift`（新增離線 executable test）
- `TypelessMLX/Sources/AppState.swift`
- `TypelessMLX/Sources/HotkeyManager.swift`
- `TypelessMLX/Sources/SettingsView.swift`
- `TypelessMLX/Sources/StatusBarController.swift`
- `Package.swift`
- `README.md`
- `tickets/TICKET-004-customizable-dictation-hotkey.md`（完成後更新狀態與驗證結果）

## 實作與驗證紀錄

- 新增 `TypelessMLXHotkeySupport` 純邏輯 target，集中 8 組左右 Option、Command、Control、Shift 的 key code、modifier、名稱、支援判斷與 key-down/key-up 轉換；無效 persisted key code 安全回退 Right Option（61）。
- 偏好設定新增「錄製快捷鍵」：支援 Escape 取消、拒絕一般按鍵／Caps Lock／未知 key code 並保留原設定；錄製期間暫停聽寫事件，設定後立即沿用既有 event monitor。
- `HotkeyManager` 依目前定義的 modifier 判斷按下／放開並去除重複 flagsChanged 轉換；選單列與設定頁共用同一顯示名稱來源。
- `README.md` 已補充預設 Right Option、自訂流程與支援範圍。
- 驗證命令（Xcode 27 SDK）：
  - `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build -c release` ✅
  - `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run -c release TypelessMLXHotkeySupportTests` ✅
  - `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run -c release TypelessMLXAudioTapFormatTests` ✅
  - `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run -c release TypelessMLXAudioInputAvailabilityTests` ✅
  - `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run -c release TypelessMLXSpeechBackendPolicyTests` ✅

備註：未使用 Xcode 的 Command Line Tools `swift build` 會因環境缺少 `SwiftUIMacros` plugin 而失敗；改用同機已安裝的 Xcode 27 SDK 後 release build 與全部 executable tests 均通過。工作區既有 `RecordingOverlay.swift`、`tickets/README.md`、`scripts/` 與 `AGENTS.md` 變更均未回復或覆寫。
