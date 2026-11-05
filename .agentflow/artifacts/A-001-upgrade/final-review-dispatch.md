# 最終差異審查派送

Review target commit: e14a1c3be57e436c8f5b1e5bbc43d3c15e17dd88

- 原 QC：/root/upgrade_qc，gpt-6.1-sol / low，原生 followup_task。
- 來源：沿用 de9644e 完整安全審查，加上 de9644e..e14a1c3be57e436c8f5b1e5bbc43d3c15e17dd88 的修正。
- 檢查 F-1、晚到 UUID 回呼、按住及切換行為、最小性。
- 唯一輸出 acceptance-final.md；初次報告及來源唯讀。共用權限，沒有系統強制唯讀。
- 保留既有集中測試與模型載入證據。主代理另執行 release HotkeySupport，退出 0。重新套件建置的編譯及簽章通過。
- 不重跑完整套件；只檢查新增風險。沿用原完整寫作指示及授權範圍，不新增代理。
