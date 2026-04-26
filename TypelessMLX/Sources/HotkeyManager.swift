import Cocoa
import Carbon

class HotkeyManager {
    static let shared = HotkeyManager()

    private var appState: AppState?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var isRecording = false
    private var recordingStartTime: Date?
    private var overlay: RecordingOverlay?
    private let lock = NSLock()
    private var isProcessing = false
    private var hotkeyIsDown = false
    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 3

    private init() {}

    func setup(appState: AppState) {
        self.appState = appState
        self.overlay = RecordingOverlay()
        setupMonitors()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioDeviceLost),
            name: .audioDeviceLost,
            object: nil
        )
        logInfo("HotkeyManager", "Setup. keyCode=\(appState.hotkeyKeyCode), mode=\(appState.hotkeyMode)")
    }

    func refreshMonitors() {
        lock.lock()
        hotkeyIsDown = false
        lock.unlock()
        setupMonitors()
        logInfo("HotkeyManager", "Monitors refreshed")
    }

    @objc private func handleAudioDeviceLost() {
        logError("HotkeyManager", "Audio device lost during recording")
        guard let appState = appState else { return }
        handleFailure(appState: appState, message: "錄音裝置中斷，請重新連接麥克風")
    }

    private func setupMonitors() {
        teardownMonitors()

        setupEventTap()

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
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags
        let flagsRaw = UInt64(flags.rawValue)
        handleHotkeyTransition(
            keyCode: keyCode,
            flagsRaw: flagsRaw,
            modifierIsActive: { hotkey in hotkey.modifier.isActive(flags) },
            source: "NSEvent.flagsChanged"
        )
    }

    private func handleCGEvent(_ event: CGEvent, type: CGEventType) {
        guard type == .flagsChanged else { return }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let flagsRaw = UInt64(flags.rawValue)

        handleHotkeyTransition(
            keyCode: keyCode,
            flagsRaw: flagsRaw,
            modifierIsActive: { hotkey in hotkey.modifier.isActive(flags) },
            source: "CGEvent.\(type.rawValue)"
        )
    }

    private func handleHotkeyTransition(
        keyCode: Int,
        flagsRaw: UInt64,
        modifierIsActive: (RecognitionHotkey) -> Bool,
        source: String
    ) {
        guard let appState = appState else { return }

        let mode = appState.hotkeyMode
        let configuredHotkey = appState.recognitionHotkey

        lock.lock()
        let wasHotkeyDown = hotkeyIsDown
        guard configuredHotkey.isRelevant(
            eventKeyCode: keyCode,
            flagsRaw: flagsRaw,
            wasHotkeyDown: wasHotkeyDown
        ) else {
            lock.unlock()
            if isConfiguredModifierFamilyEvent(hotkey: configuredHotkey, keyCode: keyCode, flagsRaw: flagsRaw) {
                logInfo("HotkeyManager", "Observed non-hotkey \(configuredHotkey.displayName) family event. keyCode=\(keyCode), configured=\(configuredHotkey.keyCode), flags=0x\(String(flagsRaw, radix: 16))")
            }
            return
        }

        let isKeyPressed = configuredHotkey.isPressed(
            eventKeyCode: keyCode,
            flagsRaw: flagsRaw,
            modifierIsActive: modifierIsActive(configuredHotkey)
        )
        guard hotkeyIsDown != isKeyPressed else {
            lock.unlock()
            logDebug("HotkeyManager", "Ignoring duplicate \(source) keyCode=\(keyCode), down=\(isKeyPressed), flags=0x\(String(flagsRaw, radix: 16))")
            return
        }
        hotkeyIsDown = isKeyPressed
        let currentlyRecording = isRecording
        let processing = isProcessing
        lock.unlock()

        logInfo("HotkeyManager", "Hotkey \(isKeyPressed ? "pressed" : "released") via \(source). keyCode=\(keyCode), configured=\(configuredHotkey.keyCode), hotkey=\(configuredHotkey.displayName), mode=\(mode), recording=\(currentlyRecording), processing=\(processing), flags=0x\(String(flagsRaw, radix: 16))")

        DispatchQueue.main.async {
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

    private func isConfiguredModifierFamilyEvent(hotkey: RecognitionHotkey, keyCode: Int, flagsRaw: UInt64) -> Bool {
        hotkey.relatedKeyCodes.contains(keyCode) || hotkey.isRelevant(eventKeyCode: keyCode, flagsRaw: flagsRaw, wasHotkeyDown: false)
    }

    private func setupEventTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                manager.handleCGEvent(event, type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            logWarn("HotkeyManager", "CGEvent tap unavailable; falling back to NSEvent flagsChanged monitors")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logWarn("HotkeyManager", "Failed to create CGEvent tap run-loop source")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logInfo("HotkeyManager", "CGEvent tap registered")
    }

    private func teardownMonitors() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapRunLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func startRecording() {
        guard let appState = appState else { return }

        lock.lock()
        guard !isRecording && !isProcessing else {
            lock.unlock()
            return
        }

        let currentStatus = appState.status
        guard currentStatus == .idle else {
            lock.unlock()
            return
        }

        isRecording = true
        isProcessing = true
        recordingStartTime = Date()
        lock.unlock()

        // If bridge was stopped by idle timer, restart it first
        let modelType = appState.selectedModel.modelType
        if modelType != "macos", !appState.hasPythonBackend {
            if appState.showFloatingOverlay {
                overlay?.show(text: "⏳ 載入模型中...", isRecording: false)
            }
            lock.lock()
            isRecording = false
            isProcessing = false
            lock.unlock()
            WhisperBridge.shared.start { [weak self] success in
                DispatchQueue.main.async {
                    AppState.shared.hasPythonBackend = success
                    if success {
                        self?.startRecording()
                    } else {
                        self?.overlay?.hide()
                    }
                }
            }
            return
        }

        appState.setStatus(.recording)
        appState.liveTranscriptionConfirmedText = ""
        appState.liveTranscriptionUnconfirmedText = ""

        if appState.showFloatingOverlay {
            overlay?.show(text: "🎙 錄音中...", isRecording: true)
        }

        // Wire audio level → overlay bars
        if appState.showFloatingOverlay, let ov = overlay {
            AudioRecorder.shared.audioLevelHandler = { level in
                ov.updateAudioLevel(level)
            }
        }

        // Start live preview (SFSpeechRecognizer partial results → text pill)
        let liveLanguage = appState.language == "auto" ? nil : appState.language
        SpeechStreamer.shared.startStreaming(language: liveLanguage)
        let ov = overlay
        SpeechStreamer.shared.liveTextHandler = { text in
            ov?.updateLiveText(text)
        }
        AudioRecorder.shared.audioBufferHandler = { buffer in
            SpeechStreamer.shared.appendBuffer(buffer)
        }

        guard AudioRecorder.shared.startRecording() else {
            AudioRecorder.shared.audioLevelHandler = nil
            AudioRecorder.shared.audioBufferHandler = nil
            SpeechStreamer.shared.cancelStreaming()
            handleFailure(appState: appState, message: "找不到可用的音訊輸入裝置，請連接或選擇麥克風")
            return
        }

        lock.lock()
        isProcessing = false
        lock.unlock()

        logInfo("HotkeyManager", "Recording started")
    }

    private func stopRecordingAndTranscribe() {
        guard let appState = appState else { return }

        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
        isRecording = false
        isProcessing = true
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        lock.unlock()

        logInfo("HotkeyManager", "Recording duration: \(String(format: "%.1f", duration))s")

        AudioRecorder.shared.audioLevelHandler = nil
        AudioRecorder.shared.audioBufferHandler = nil
        SpeechStreamer.shared.stopStreaming()

        AudioRecorder.shared.stopRecording { [weak self] audioURL in
            guard let self = self else { return }

            guard let audioURL = audioURL else {
                logError("HotkeyManager", "stopRecording returned nil URL")
                SpeechStreamer.shared.cancelStreaming()
                self.handleFailure(appState: appState, message: "錄音失敗，未取得音訊檔案")
                return
            }

            // Skip very short recordings (< 0.3s)
            if duration < 0.3 {
                logInfo("HotkeyManager", "Recording too short (\(String(format: "%.2f", duration))s), skipping")
                SpeechStreamer.shared.cancelStreaming()
                self.resetState()
                DispatchQueue.main.async {
                    appState.setStatus(.idle)
                    self.overlay?.hide()
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            DispatchQueue.main.async {
                appState.setStatus(.transcribing)
                if appState.showFloatingOverlay {
                    self.overlay?.show(text: "⏳ 辨識中...", isRecording: false)
                }
            }

            let language = appState.language == "auto" ? nil : appState.language

            let handleResult: (Result<String, Error>) -> Void = { [weak self] result in
                guard let self = self else { return }
                try? FileManager.default.removeItem(at: audioURL)

                DispatchQueue.main.async {
                    // Clear live text pill — final result replaces it
                    self.overlay?.updateLiveText("")
                    self.overlay?.hide()

                    switch result {
                    case .success(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            logWarn("HotkeyManager", "Transcription returned empty text")
                            self.resetState()
                            appState.setStatus(.idle)
                            return
                        }

                        logInfo("HotkeyManager", "Transcription success: \(trimmed.prefix(80))...")
                        self.consecutiveFailures = 0

                        let entry = TranscriptionEntry(text: trimmed, duration: duration, model: appState.selectedModelID)
                        appState.addToHistory(entry)

                        TextPaster.shared.pasteText(trimmed)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.resetState()
                            appState.setStatus(.idle)
                        }

                    case .failure(let error):
                        logError("HotkeyManager", "Transcription failed: \(error.localizedDescription)")
                        let isTimeout = (error as NSError).code == -4
                        let isFirstRun = appState.selectedModel.modelType == "qwen3"
                        let message = isTimeout && isFirstRun
                            ? "模型首次載入需下載 ~1GB，請稍候幾分鐘再試（選單列顯示辨識中時請勿關閉 App）"
                            : "辨識失敗：\(error.localizedDescription)"
                        self.handleFailure(appState: appState, message: message)
                    }
                }
            }

            // Route to correct ASR backend
            if appState.selectedModel.modelType == "macos" {
                logInfo("HotkeyManager", "Using macOS built-in ASR")
                SpeechStreamer.shared.transcribe(audioURL: audioURL, language: language, completion: handleResult)
            } else {
                let model = appState.resolvedModelPath
                logInfo("HotkeyManager", "Sending to WhisperBridge. Model: \(model.split(separator: "/").last ?? Substring(model))")
                WhisperBridge.shared.transcribe(audioURL: audioURL, model: model, language: language, completion: handleResult)
            }
        }
    }

    private func handleFailure(appState: AppState, message: String) {
        consecutiveFailures += 1
        logWarn("HotkeyManager", "Failure #\(consecutiveFailures): \(message)")

        if consecutiveFailures >= HotkeyManager.maxConsecutiveFailures {
            logError("HotkeyManager", "Too many consecutive failures (\(consecutiveFailures)), performing hard reset")
            AudioRecorder.shared.forceReset()
            consecutiveFailures = 0
        }

        resetState()
        DispatchQueue.main.async {
            appState.setStatus(.idle)
            appState.showError(message)
            self.overlay?.hide()
        }
    }

    private func resetState() {
        lock.lock()
        isRecording = false
        isProcessing = false
        recordingStartTime = nil
        lock.unlock()
    }

    deinit {
        teardownMonitors()
        NotificationCenter.default.removeObserver(self)
    }
}
