import Cocoa
import Carbon
import TypelessMLXHotkeySupport
import TypelessMLXWorkflowSupport
import TypelessMLXTextSupport

class HotkeyManager {
    static let shared = HotkeyManager()

    private var appState: AppState?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isRecording = false
    private var recordingStartTime: Date?
    private var overlay: RecordingOverlay?
    private let lock = NSLock()
    private var isProcessing = false
    private var hotkeyIsPressed = false
    private var lastHotkeyKeyCode: Int?
    private var hotkeyCaptureIsActive = false
    private let lifecycle = DictationLifecycle()
    private var target: PasteTarget?
    private var taskModel: MLXModel?
    private var taskModelPath: String?
    private var taskLanguage: String?
    private var taskAudioURL: URL?
    private var taskDuration: TimeInterval = 0
    private var taskStopTime: Date?
    private var taskRoutingStartTime: Date?
    private var taskGainDB: Double = 0
    private var taskGainChanges: [Double] = []
    private var clippingWarning = false
    private var isPreparingModel = false
    private var retrySourceID: UUID?
    private var timeout: DispatchWorkItem?
    private var refinementTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?

    private init() {}

    func setup(appState: AppState) {
        self.appState = appState
        self.overlay = RecordingOverlay()
        setupMonitors()
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { DispatchQueue.main.async { self?.cancelCurrentTask() } }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.hotkeyCaptureIsActive == false,
               self?.lifecycle.phase.isTerminal == false {
                self?.cancelCurrentTask()
                return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioDeviceLost),
            name: .audioDeviceLost,
            object: nil
        )
        logInfo("HotkeyManager", "Setup. keyCode=\(appState.hotkeyKeyCode), mode=\(appState.hotkeyMode)")
    }

    /// Temporarily suppress dictation events while the settings window is
    /// recording a replacement modifier.  The event monitors remain in place
    /// so changing a hotkey takes effect immediately without rebuilding them.
    func setHotkeyCaptureActive(_ active: Bool) {
        lock.lock()
        hotkeyCaptureIsActive = active
        if active {
            hotkeyIsPressed = false
            lastHotkeyKeyCode = nil
        }
        lock.unlock()
    }

    @objc private func handleAudioDeviceLost() {
        logError("HotkeyManager", "Audio device lost during recording")
        guard let appState = appState else { return }
        handleFailure(appState: appState, message: "錄音裝置中斷，請重新連接麥克風")
    }

    private func setupMonitors() {
        // Global monitor — fires when other apps are focused
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Local monitor — fires when our app is focused
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        logInfo("HotkeyManager", "Flag monitors registered")
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let appState = appState else { return }

        let definition = appState.hotkeyDefinition
        let keyCode = Int(event.keyCode)
        guard keyCode == definition.keyCode else { return }

        let modifierState = HotkeyModifierState(
            eventModifierFlagsRawValue: event.modifierFlags.rawValue
        )
        let isKeyPressed = definition.isKeyDown(for: modifierState)
        let mode = appState.hotkeyMode

        lock.lock()
        guard !hotkeyCaptureIsActive else {
            lock.unlock()
            return
        }
        if lastHotkeyKeyCode != definition.keyCode {
            lastHotkeyKeyCode = definition.keyCode
            hotkeyIsPressed = false
        }
        // A flagsChanged monitor can receive duplicate state notifications
        // when multiple modifier keys are held.  Only one transition per
        // physical press/release may affect dictation.
        guard hotkeyIsPressed != isKeyPressed else {
            lock.unlock()
            return
        }
        hotkeyIsPressed = isKeyPressed
        lock.unlock()

        DispatchQueue.main.async {
            self.lock.lock()
            let currentlyRecording = self.isRecording
            let processing = self.isProcessing
            self.lock.unlock()

            if mode == "hold" {
                // Hold-to-talk: press=start, release=stop
                if isKeyPressed && !currentlyRecording && !processing {
                    self.startRecording()
                } else if !isKeyPressed && currentlyRecording {
                    self.stopRecordingAndTranscribe()
                }
            } else {
                // Toggle mode: each key-down toggles
                if isKeyPressed {  // key-down event
                    if !currentlyRecording && !processing {
                        self.startRecording()
                    } else if currentlyRecording {
                        self.stopRecordingAndTranscribe()
                    }
                }
                // key-up (isKeyPressed=false) is ignored in toggle mode
            }
        }
    }

    private func startRecording() {
        guard let appState, appState.status == .idle else { return }
        lock.lock()
        guard !isRecording && !isProcessing else { lock.unlock(); return }
        isProcessing = true
        lock.unlock()
        let id = lifecycle.begin()
        taskDuration = 0
        taskStopTime = nil
        taskRoutingStartTime = nil
        taskAudioURL = nil
        target = TextPaster.captureTarget()
        taskModel = appState.selectedModel
        taskModelPath = appState.resolvedModelPath
        taskLanguage = appState.language == "auto" ? nil : appState.language
        taskGainDB = appState.inputGainDB
        taskGainChanges = [taskGainDB]
        clippingWarning = false
        retrySourceID = nil
        prepareBackend(id) { [weak self] in self?.beginAudio(id) }
    }

    private func prepareBackend(_ id: UUID, ready: @escaping () -> Void) {
        guard let appState, lifecycle.isCurrent(id), let model = taskModel else { return }
        if model.modelType == "macos" { ready(); return }
        appState.setStatus(.preparing)
        if appState.showFloatingOverlay { showOverlay(text: "模型準備中…按 Esc 取消", isRecording: false) }
        // 模型管理器負責下載與驗證；一般辨識逾時從準備完成後才開始。
        isPreparingModel = true
        ModelManager.shared.prepare(model) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.lifecycle.isCurrent(id) else { return }
                self.isPreparingModel = false
                switch result {
                case .failure(let error): self.failTask(id, message: "模型準備失敗：\(error.localizedDescription)")
                case .success(let path):
                    self.taskModelPath = path
                    if appState.hasPythonBackend { ready(); return }
                    WhisperBridge.shared.start { [weak self] success in
                        DispatchQueue.main.async {
                            guard let self, self.lifecycle.isCurrent(id) else { return }
                            appState.hasPythonBackend = success
                            if success { ready() }
                            else { self.failTask(id, message: "後端啟動失敗，請開啟設定與安裝視窗") }
                        }
                    }
                }
            }
        }
    }

    private func beginAudio(_ id: UUID) {
        guard let appState, lifecycle.isCurrent(id) else { return }
        appState.setStatus(.recording)
        appState.liveTranscriptionConfirmedText = ""
        appState.liveTranscriptionUnconfirmedText = ""
        recordingStartTime = Date()
        AudioRecorder.shared.setInputGainDB(appState.inputGainDB)
        if appState.showFloatingOverlay {
            showOverlay(text: "錄音中…按 Esc 取消", isRecording: true)
            AudioRecorder.shared.audioLevelHandler = { [weak self] level in self?.overlay?.updateAudioLevel(level) }
            AudioRecorder.shared.clippingHandler = { [weak self] ratio in
                DispatchQueue.main.async {
                    guard let self, self.lifecycle.isCurrent(id), self.lifecycle.phase == .recording else { return }
                    if ratio > 0.01 { self.clippingWarning = true
                        self.overlay?.updateLiveText("音訊削波，請降低輸入增益") }
                }
            }
        }
        SpeechStreamer.shared.startStreaming(language: taskLanguage)
        SpeechStreamer.shared.liveTextHandler = { [weak self] text in
            guard let self, self.lifecycle.isCurrent(id), self.lifecycle.phase == .recording else { return }
            self.overlay?.updateLiveText(self.clippingWarning ? "音訊削波，請降低輸入增益" : text)
        }
        AudioRecorder.shared.audioBufferHandler = { buffer in SpeechStreamer.shared.appendBuffer(buffer) }
        guard AudioRecorder.shared.startRecording() else {
            failTask(id, message: "找不到可用的音訊輸入裝置，請連接或選擇麥克風")
            return
        }
        lock.lock(); isRecording = true; isProcessing = false; lock.unlock()
    }

    private func stopRecordingAndTranscribe() {
        guard let id = lifecycle.id, lifecycle.isCurrent(id), lifecycle.phase == .recording else { return }
        lock.lock()
        guard isRecording else { lock.unlock(); return }
        isRecording = false; isProcessing = true
        lock.unlock()
        taskStopTime = Date()
        taskDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
        taskGainChanges = AudioRecorder.shared.gainChanges
        clearAudioHandlers()
        SpeechStreamer.shared.stopStreaming()
        AudioRecorder.shared.stopRecording { [weak self] url in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.lifecycle.isCurrent(id) else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.taskAudioURL = url
                guard url != nil else { self.failTask(id, message: "錄音失敗，未取得音訊檔案"); return }
                if self.taskDuration < 0.3 { self.cancelCurrentTask(); return }
                self.recognize(id)
            }
        }
    }

    private func recognize(_ id: UUID) {
        guard let appState, lifecycle.isCurrent(id), let audio = taskAudioURL, let model = taskModel else { return }
        taskRoutingStartTime = Date()
        lifecycle.transition(id, to: .recognizing)
        appState.setStatus(.transcribing)
        if appState.showFloatingOverlay { showOverlay(text: "辨識中…按 Esc 取消", isRecording: false) }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.lifecycle.isCurrent(id), self.lifecycle.phase == .recognizing else { return }
            self.failTask(id, message: "辨識超過 120 秒，可從歷史重試")
            self.stopBackends()
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: deadline)
        let completion: (Result<String, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.lifecycle.isCurrent(id), self.lifecycle.phase == .recognizing else { return }
                self.timeout?.cancel(); self.timeout = nil
                switch result {
                case .failure(let error): self.failTask(id, message: "辨識失敗：\(error.localizedDescription)")
                case .success(let raw):
                    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.failTask(id, message: "未辨識到文字，可從歷史重試"); return
                    }
                    // 成功辨識後只需文字救援，立即移除音訊。
                    self.deleteTaskAudio()
                    self.processText(raw, id: id)
                }
            }
        }
        if model.modelType == "macos" {
            SpeechStreamer.shared.transcribe(audioURL: audio, language: taskLanguage,
                contextualStrings: appState.nativeSpeechContextualStrings, completion: completion)
        } else {
            WhisperBridge.shared.transcribe(audioURL: audio, model: taskModelPath, language: taskLanguage, modelType: model.modelType, completion: completion)
        }
    }

    private func processText(_ raw: String, id: UUID) {
        guard let appState, lifecycle.isCurrent(id) else { return }
        lifecycle.transition(id, to: .refining)
        appState.setStatus(.refining)
        let substituted = appState.enableVocabularyReplacements ? DictionaryService.shared.applyReplacements(raw) : raw
        let cleanup = appState.removeFillers ? TextCleanup.removingHesitations(substituted) : substituted
        let beforeRefinement = cleanup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? substituted : cleanup
        let finish: (String) -> Void = { [weak self] final in
            guard let self, self.lifecycle.isCurrent(id), self.lifecycle.phase == .refining else { return }
            self.deliver(raw: raw, substituted: substituted, final: final, id: id)
        }
        if appState.enableTextRefinement, #available(macOS 26, *) {
            refinementTask = Task {
                let outcome = await TextRefiner.shared.refineDetailed(beforeRefinement)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.lifecycle.isCurrent(id), self.lifecycle.phase == .refining else { return }
                    let note: String?
                    if outcome.failure == .timeout { note = "標點整理逾時，已保留整理前文字。" }
                    else if outcome.failure != nil { note = "標點整理未通過或不可用，已保留整理前文字。" }
                    else { note = nil }
                    self.deliver(raw: raw, substituted: substituted, final: outcome.text, id: id, note: note)
                }
            }
        } else { finish(beforeRefinement) }
    }

    private func deliver(raw: String, substituted: String, final: String, id: UUID, note: String? = nil) {
        guard let appState, lifecycle.isCurrent(id) else { return }
        logFinalLatency()
        lifecycle.transition(id, to: .awaitingInput)
        appState.setStatus(.awaitingInput)
        let entry = TranscriptionEntry(id: id, text: final, duration: taskDuration,
            model: taskModel?.id ?? "", originalText: raw, substitutedText: substituted,
            refinedText: final, failureReason: note, gainDB: taskGainDB, gainChanges: taskGainChanges)
        appState.addToHistory(entry)
        if retrySourceID != nil {
            appState.updateHistory(id) { $0.phase = .awaitingInput; $0.delivery = .retained }
            finishTask(id, phase: .completed)
            return
        }
        TextPaster.shared.pasteText(final, target: target, isCurrent: { [weak self] in self?.lifecycle.isCurrent(id) == true }) { [weak self] outcome in
            guard let self, self.lifecycle.isCurrent(id) else { return }
            appState.updateHistory(id) {
                $0.delivery = outcome
                $0.phase = outcome == .sent ? .completed : (outcome == .cancelled ? .cancelled : .awaitingInput)
            }
            if outcome == .failed {
                appState.showError("未送出貼上。請檢查輔助使用權限，或在歷史按「複製」。")
            } else if outcome == .retained {
                appState.showError("輸入目標已變更或無法確認。請在歷史按「複製」。")
            } else if outcome == .blocked {
                appState.showError("安全輸入啟用中，未貼上或複製。結果已保留在歷史。")
            }
            self.finishTask(id, phase: outcome == .cancelled ? .cancelled : .completed)
        }
    }

    func retryHistory(_ entry: TranscriptionEntry) {
        appState?.refreshRecoveryReferences()
        guard let appState, appState.status == .idle, let recoveryID = entry.recoveryID,
              let audio = appState.recoveryStore?.url(for: recoveryID) else {
            appState?.showError("救援錄音已過期或目前正在處理")
            return
        }
        let id = lifecycle.begin()
        retrySourceID = entry.id
        target = nil
        taskAudioURL = audio
        taskDuration = entry.duration
        taskStopTime = Date()
        taskRoutingStartTime = nil
        taskGainDB = entry.gainDB ?? 0
        taskGainChanges = entry.gainChanges ?? [taskGainDB]
        taskModel = AppState.availableModels.first { $0.id == entry.model } ?? appState.selectedModel
        taskModelPath = nil
        taskLanguage = appState.language == "auto" ? nil : appState.language
        lock.lock(); isProcessing = true; lock.unlock()
        prepareBackend(id) { [weak self] in self?.recognize(id) }
    }

    func cancelCurrentTask() {
        guard let appState, let id = lifecycle.id, lifecycle.isCurrent(id) else { return }
        // 先使識別碼失效，再停止會觸發回呼的資源。
        lifecycle.finish(id, phase: .cancelled)
        if isPreparingModel { ModelManager.shared.cancelDownload(); isPreparingModel = false }
        timeout?.cancel(); timeout = nil
        refinementTask?.cancel(); refinementTask = nil
        appState.updateHistory(id) { $0.phase = .cancelled; $0.delivery = .cancelled }
        deleteTaskAudio()
        clearAudioHandlers()
        AudioRecorder.shared.forceReset()
        stopBackends()
        resetState()
        appState.setStatus(.idle)
        overlay?.hide()
    }

    private func failTask(_ id: UUID, message: String) {
        guard let appState, lifecycle.isCurrent(id) else { return }
        logFinalLatency()
        var recovery: String?
        var failureMessage = message
        if let audio = taskAudioURL {
            if let source = retrySourceID {
                recovery = appState.history.first(where: { $0.id == source })?.recoveryID
            } else if appState.retainFailedAudio {
                do { recovery = try appState.recoveryStore?.retain(audio) }
                catch { logError("Recovery", "保存失敗：\(error)") }
                if recovery == nil { failureMessage += "；錄音未能保存，請重新錄音。" }
            }
            if retrySourceID == nil { try? FileManager.default.removeItem(at: audio) }
        }
        taskAudioURL = nil
        appState.addToHistory(TranscriptionEntry(id: id, text: "", duration: taskDuration,
            model: taskModel?.id ?? appState.selectedModelID, delivery: .failed, failureReason: failureMessage,
            recoveryID: recovery, phase: .failed, gainDB: taskGainDB))
        appState.refreshRecoveryReferences()
        clearAudioHandlers()
        AudioRecorder.shared.forceReset()
        SpeechStreamer.shared.cancelStreaming()
        SpeechStreamer.shared.cancelTranscription()
        appState.showError(failureMessage)
        finishTask(id, phase: .failed)
    }

    private func deleteTaskAudio() {
        if let url = taskAudioURL { try? FileManager.default.removeItem(at: url) }
        if let source = retrySourceID, let appState {
            appState.updateHistory(source) { $0.recoveryID = nil }
        }
        taskAudioURL = nil
        appState?.refreshRecoveryReferences()
    }
    private func stopBackends() {
        SpeechStreamer.shared.cancelStreaming()
        SpeechStreamer.shared.cancelTranscription()
        if taskModel?.modelType != "macos" {
            WhisperBridge.shared.stopProcess()
            appState?.hasPythonBackend = false
        }
    }
    private func logFinalLatency() {
        guard let stopped = taskStopTime, let routed = taskRoutingStartTime else { return }
        let total = Date().timeIntervalSince(stopped)
        let routing = Date().timeIntervalSince(routed)
        logInfo("HotkeyManager", "Final result telemetry: model=\(taskModel?.id ?? "") keyUpToFinal=\(String(format: "%.3f", total))s routing=\(String(format: "%.3f", routing))s gainDB=\(taskGainDB)")
    }
    private func showOverlay(text: String, isRecording: Bool) {
        overlay?.show(text: text, isRecording: isRecording)
        overlay?.updateLiveText(text)
    }
    private func clearAudioHandlers() {
        AudioRecorder.shared.audioLevelHandler = nil
        AudioRecorder.shared.audioBufferHandler = nil
        AudioRecorder.shared.clippingHandler = nil
    }
    private func finishTask(_ id: UUID, phase: DictationPhase) {
        guard lifecycle.finish(id, phase: phase) else { return }
        timeout?.cancel(); timeout = nil
        refinementTask = nil
        clearAudioHandlers()
        SpeechStreamer.shared.cancelStreaming()
        resetState()
        overlay?.hide()
        appState?.setStatus(.idle)
    }
    private func handleFailure(appState: AppState, message: String) {
        guard let id = lifecycle.id else { return }
        failTask(id, message: message)
    }
    private func resetState() {
        lock.lock()
        isRecording = false; isProcessing = false; recordingStartTime = nil
        lock.unlock()
        taskAudioURL = nil; target = nil; retrySourceID = nil
    }
    deinit {
        for monitor in [flagsMonitor, localFlagsMonitor, escapeMonitor, localEscapeMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        NotificationCenter.default.removeObserver(self)
    }
}
