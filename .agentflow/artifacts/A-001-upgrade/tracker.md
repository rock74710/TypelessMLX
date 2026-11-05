# Tracker

## Identity

- **Work key:** A-001-upgrade.
- **Active Ask:** A-001.
- **Goal:** 依升級計劃完成 A–E，保留既有修改。
- **Last update:** 2026-11-05 13:41:00 +0800.
- **Evidence commit:** e14a1c3be57e436c8f5b1e5bbc43d3c15e17dd88.

## Overall state

- **State:** complete.
- **Reason:** A–E 程式、測試、獨立審查與套件完成；實機及品質限制已明列。
- **Total:** 6.
- **Completed:** 6.
- **Remaining:** 0.

## Accepted task checklist

- [x] **T-1:** A：TextPaster 與 HotkeyManager 擷取及重查目標；序列化貼上；剪貼簿所有權檢查；回報事件送出。用獨立剪貼簿驗證競態與目標變更；無法確認則保留文字。Source: A-001 升級計劃 A。 Proof: WorkflowTests passed；acceptance-final.md R-1 / INV-1。
- [x] **T-2:** B：HotkeyManager、WhisperBridge、SpeechStreamer、AppState 加入任務識別、取消、逾時與救援保存；SettingsView 提供重試與清除。測試舊歷史、晚到結果、保存上限。失敗保留可救援資料。Source: A-001 升級計劃 B。 Proof: Workflow、Bridge passed；acceptance-final.md R-2 / INV-2–3。
- [x] **T-3:** C：ModelManager、SetupWindowController、backend 固定來源與驗證；不完整模型不得就緒；保留 8-bit、FP16、遠端順序。測試損壞、缺檔與標記失效；修復失敗保留可用模型。Source: A-001 升級計劃 C。 Proof: ModelReadiness、十五個 Python 測試與本機 Breeze loader passed；acceptance-final.md R-3 / INV-4。
- [x] **T-4:** D：AudioRecorder 與 AudioSupport 加入一次性增益；SettingsView 與指示器顯示削波。測試 0/+6 dB、多聲道、有限值與一致分流。60 段音檔與實機評測缺資料時明列未驗證。Source: A-001 升級計劃 D。 Proof: GainAndText passed；acceptance-final.md R-4 / INV-5。實機與語料未驗證。
- [x] **T-5:** E：DictionaryService、TextRefiner、SettingsView 加入人工對照、啟用、刪除、撤銷與來源；原文分存。測試邊界、最長符合、不連鎖與整理回退。Source: A-001 升級計劃 E。 Proof: GainAndText passed；acceptance-final.md R-5 / INV-6。
- [x] **T-6:** 整合：release build、四個既有測試及新增測試、獨立審查、HTML 交付紀錄；只提交本輪變更。實機與音檔不足明列限制。Source: A-001 發布前檢查。 Proof: release build、全部集中測試、acceptance-final.md PASS、最終 App 與 DMG 建置退出 0。

## Accepted scope changes

- None.

## Current recovery

- **Current item:** none.
- **Last proven result:** release、八組 Swift、十五個 Python 測試、本機 Breeze loader、簽署 App 與 DMG 全部通過。
- **Active blocker or running process:** none.
- **Next safe action:** none.
- **Expected changed files:** Package.swift、TypelessMLX/Sources、TypelessMLX/AudioSupport、TypelessMLX/HotkeySupport、TypelessMLX/Tests、backend、docs/explain/2026-11-05-upgrade-result.html、.agentflow/artifacts/A-001-upgrade、.agentflow/devlog.md。

## Completion proof

- **All accepted tasks checked:** yes.
- **Blocking accepted decision:** none.
- **Operation running:** no.
- **Next action remaining:** none.
- **Evidence status:** complete.
- **Judgment:** complete.

## Update meaning

- Saving this tracker is a recovery checkpoint, not a stop signal.
- Work continues with the next unfinished item unless an independent stop condition applies.
