2026-11-05 13:38:27 +0800 | gpt-6.1-sol / low

Reviewed implementation commit: de9644e2bd7e8cc911284986d56a227aaa8aaadb

- **結果：阻擋交付。** 按住模式在模型準備期間放開按鍵，仍會稍後開始錄音。請先修正，再審查新提交。

- **證據限制：** 自動測試與本機模型載入通過，不代表實機麥克風或常用 App 已驗收。

- **範圍：** 本報告合併安全與功能驗收。只審查上述提交，不包含工作中的修正。

Outcome: BLOCKING

Minimality: PASS

Conformance: PASS

Verdict: BLOCKING

## 發現

- **F-1／高／必須修正：放開按鍵後仍可能開始錄音。** 位置：`TypelessMLX/Sources/HotkeyManager.swift:136`、`:176`、`:208`。

  觸發：使用按住模式。按下快捷鍵後，在模型準備完成前放開。

  證據：放開分支只處理 `currentlyRecording == true`。準備期間只有 `isProcessing` 為真。放開事件因此被忽略。準備成功後，`beginAudio` 只檢查任務識別碼，沒有檢查按鍵是否仍按住。

  影響：使用者已結束按住操作，App 卻稍後啟動麥克風。錄音會持續到下次操作或 Esc。

  範圍判斷：舊版停止後端的重啟路徑已有類似缺陷。本輪將非原生模型的每次錄音都改成先準備，因此擴大到後端正常的使用流程。這是本輪流程整合問題。

  修正：準備期間放開按鍵時，結束該次按住任務。晚到成功回呼不得啟動錄音。加入延遲準備、提早放開、再次按下與切換模式的測試。

## 需求與安全界線

| 需求 | 審查結果與證據 |
| --- | --- |
| R-1／INV-1 | 貼上交易依版本與所有權還原。送出前重查任務、目標及安全輸入。`WorkflowSupport/PasteTransaction.swift:31`、`:78`；`Sources/TextPaster.swift:76`。獨立剪貼簿及自有編輯器測試涵蓋新複製、接續任務、空快照、選取變更及拒絕送出。 |
| R-2／INV-2 | UUID 隔離、終止一次、Esc、辨識逾時及後端程序隔離已接上。`Sources/HotkeyManager.swift:259`、`:383`；`Sources/WhisperBridge.swift:216`；`WorkflowSupport/DictationRecord.swift:11`。F-1 阻擋正常按住流程。 |
| R-2／INV-3 | 救援使用本機私有目錄與 UUID 檔名。目錄 0700、錄音 0600。啟動與寫入清理時間、數量及大小。重試只產生歷史結果。`WorkflowSupport/RecoveryStore.swift:9`；`Sources/AppState.swift:300`；`Sources/HotkeyManager.swift:346`。成功與取消刪除錄音。 |
| R-3／INV-4 | 遠端 revision、必要檔案大小及可信雜湊固定在 manifest。先驗證再載入，最後原子寫入標記。標記比對檔案指紋，正常啟動不完整載入。轉換記錄與遠端信任分開。`backend/model_validation.py:119`、`:244`；`backend/transcribe_server.py:156`；`backend/convert.py:255`。轉換先完成暫存產物，再發布；失敗時保留舊目錄。 |
| R-4／INV-5 | 增益處理一次，之後才寫 WAV、計算音量與送出預覽。同一個 buffer 分流。處理多聲道、非有限值及削波。`Sources/AudioRecorder.swift:153`；`AudioSupport/AudioGainProcessor.swift:83`。未取得實機及品質語料，不宣稱小聲或氣音辨識改善。 |
| R-5／INV-6 | 替換只掃描原輸入，採最長符合。英文檢查邊界，中文規則需確認。整理驗證詞彙、數字、空白、原有標點及控制標記。逾時回退。`TextSupport/VocabularyCorrection.swift:73`；`TextSupport/PunctuationRefinementValidator.swift:52`；`Sources/TextRefiner.swift:55`。UI 提供新增、停用、刪除、撤銷、原文複製與還原。 |

## 最小性檢查

- 獨立嘗試刪除貼上交易的序列化等待，直接重用原有貼上函式。沿第一筆送出、第二筆寫入、第一筆還原的順序推演，舊快照會干擾後續任務。現有所有權與序列化各有作用，不能刪除其中一項。

- 嘗試合併詞彙替換與標點整理。人工規則允許改詞，標點整理必須拒絕改詞。合併會失去兩種不同授權的界線，因此保留分開處理。

- 新支援模組提供可注入的測試界面，沿用既有 Swift、後端、設定及歷史。未見新增引擎、雲端、自動學習或額外依賴。F-1 可在現有協調器內修正，不需要重構。

## 驗證與交付限制

- 沿用協調者對此提交的驗證：release build、六個可執行測試目標、Bridge 測試、ModelReadiness 合約測試，以及十五個 Python 測試通過。首次測試發現缺少 `sys` 匯入，修正已納入受審提交。

- 沿用本機 Breeze 8-bit 的準備及實際 `_load_whisper` 通過證據。本次未重跑相同套件，也未下載模型。

- F-1 由確定的控制流程確認。現有測試沒有涵蓋準備期間放開快捷鍵。新提交需補此情境，並確認取消後的晚到準備結果無作用。

- 實機麥克風、常用 App 的輔助使用欄位，以及六十段品質語料仍未驗證。這些是已允許的交付限制，不單獨阻擋本次功能交付。

- 裝置中斷時，尚未交給協調器的暫存錄音會由 `AudioRecorder.forceReset` 刪除。現有合約承諾辨識失敗救援，未明定中斷錄音救援。本項不新增阻擋；若需保留部分錄音，另列提案。

- 已核對 Ask、設計合約、升級計劃與 review-facts。產品變更落在 A–E。提交、notebook、STATUS 與路由紀錄的最終收尾仍由協調者更新；本報告不將待收尾紀錄當成已完成。

Self-check: 已核對受審提交、R-1–R-5、INV-1–INV-6、安全界線、最小性、授權範圍與證據限制；只寫入本報告，未修改產品或重跑既有套件。
