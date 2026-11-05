import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import TypelessMLXHotkeySupport
import TypelessMLXWorkflowSupport
import TypelessMLXTextSupport

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("一般", systemImage: "gear") }
                .tag(0)

            ModelSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("模型", systemImage: "waveform") }
                .tag(1)

            HistorySettingsTab()
                .environmentObject(appState)
                .tabItem { Label("歷史", systemImage: "clock") }
                .tag(2)
        }
        .frame(width: 560, height: 600)
        .padding()
    }
}

// MARK: - General Tab

/// Owns the local event monitor used while the user records a replacement
/// modifier.  It is kept separate from the SwiftUI value view so the monitor
/// token has an explicit lifetime and is always removed on cancellation.
private final class HotkeyCaptureMonitor: ObservableObject {
    private var monitor: Any?
    private var handler: ((NSEvent) -> Bool)?

    func start(handler: @escaping (NSEvent) -> Bool) {
        stop()
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handler?(event) == true ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        handler = nil
    }

    deinit {
        stop()
        HotkeyManager.shared.setHotkeyCaptureActive(false)
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var inputDevices: [(name: String, uid: String)] = []
    @StateObject private var hotkeyCaptureMonitor = HotkeyCaptureMonitor()
    @State private var isRecordingHotkey = false
    @State private var hotkeyCaptureMessage: String?
    @State private var hotkeyCaptureMessageIsError = false

    var body: some View {
        Form {
            Section("快捷鍵") {
                HStack {
                    Text("辨識快捷鍵")
                    Spacer()
                    Text(appState.hotkeyDefinition.displayName).foregroundColor(.secondary)
                    Button(isRecordingHotkey ? "等待按鍵…" : "錄製快捷鍵") {
                        if isRecordingHotkey {
                            finishHotkeyCapture(message: "已取消快捷鍵錄製", isError: false)
                        } else {
                            beginHotkeyCapture()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if isRecordingHotkey {
                    Label(
                        "請按一下 Option、Command、Control 或 Shift；按 Esc 取消",
                        systemImage: "record.circle"
                    )
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }

                if let hotkeyCaptureMessage {
                    Text(hotkeyCaptureMessage)
                        .font(.caption)
                        .foregroundColor(hotkeyCaptureMessageIsError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("模式", selection: $appState.hotkeyMode) {
                    Text("切換模式（按一下開始，再按停止）").tag("toggle")
                    Text("按住模式（按住錄音，放開停止）").tag("hold")
                }
            }

            Section("錄音裝置") {
                Picker("輸入裝置", selection: $appState.inputDeviceUID) {
                    Text("系統預設").tag("")
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }

            Section("輸入增益") {
                Stepper("\(Int(appState.inputGainDB)) dB", value: $appState.inputGainDB, in: -6...12, step: 3)
                    .onChange(of: appState.inputGainDB) { AudioRecorder.shared.setInputGainDB($0) }
                Button("回到 0 dB") { appState.inputGainDB = 0 }
                Text("只調整 App 音訊。下一段音訊生效；削波時請降低增益。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("顯示") {
                Toggle("顯示浮動錄音指示器", isOn: $appState.showFloatingOverlay)
                Toggle("開機自動啟動", isOn: $appState.launchAtLogin)
                    .onChange(of: appState.launchAtLogin) { newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section("權限狀態") {
                HStack {
                    Text("麥克風")
                    Spacer()
                    PermissionBadge(granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
                }
                HStack {
                    Text("輔助使用（Accessibility）")
                    Spacer()
                    PermissionBadge(granted: AXIsProcessTrusted())
                }
                if !appState.hasAccessibilityPermission {
                    Button("開啟輔助使用設定") { TextPaster.openAccessibilitySettings() }
                }
                if appState.requiresPythonBackend {
                    HStack {
                        Text("Python 後端")
                        Spacer()
                        PermissionBadge(granted: appState.hasPythonBackend)
                    }
                } else {
                    HStack {
                        Text("macOS 語音辨識")
                        Spacer()
                        Text("自動路由")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(nativeSpeechStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("開啟系統設定") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .buttonStyle(.link)
            }

            Section("關於") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersion).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            inputDevices = AudioRecorder.availableInputDevices()
        }
        .onDisappear {
            finishHotkeyCapture()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (build \(build))"
    }

    private var nativeSpeechStatusText: String {
        if #available(macOS 26, *) {
            return "macOS 26+ 優先使用新的 Speech API；若語系、系統能力或資產不支援，會自動切換相容模式。"
        }
        return "此 macOS 版本使用相容模式；升級至 macOS 26+ 後會優先使用新的 Speech API。"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                logWarn("Settings", "Failed to set launch at login: \(error)")
            }
        }
    }

    private func beginHotkeyCapture() {
        hotkeyCaptureMessage = nil
        hotkeyCaptureMessageIsError = false
        isRecordingHotkey = true
        HotkeyManager.shared.setHotkeyCaptureActive(true)
        hotkeyCaptureMonitor.start { [self] event in
            handleHotkeyCaptureEvent(event)
        }
    }

    @discardableResult
    private func handleHotkeyCaptureEvent(_ event: NSEvent) -> Bool {
        guard isRecordingHotkey else { return false }

        let keyCode = Int(event.keyCode)
        if event.type == .keyDown {
            if keyCode == HotkeyDefinition.escapeKeyCode {
                finishHotkeyCapture(message: "已取消快捷鍵錄製", isError: false)
            } else {
                finishHotkeyCapture(
                    message: HotkeyDefinition.unsupportedKeyMessage(forKeyCode: keyCode),
                    isError: true
                )
            }
            return true
        }

        guard let definition = HotkeyDefinition.definition(forKeyCode: keyCode) else {
            finishHotkeyCapture(
                message: HotkeyDefinition.unsupportedKeyMessage(forKeyCode: keyCode),
                isError: true
            )
            return true
        }

        let modifierState = HotkeyModifierState(
            eventModifierFlagsRawValue: event.modifierFlags.rawValue
        )
        // A flagsChanged event is emitted for both press and release.  Only
        // accept the press transition so a key released after opening the
        // settings window cannot overwrite the current choice.
        guard definition.isKeyDown(for: modifierState) else { return false }

        appState.hotkeyKeyCode = definition.keyCode
        finishHotkeyCapture(
            message: "快捷鍵已設定為 \(definition.displayName)",
            isError: false
        )
        return true
    }

    private func finishHotkeyCapture(message: String? = nil, isError: Bool = false) {
        guard isRecordingHotkey || message != nil else { return }
        hotkeyCaptureMonitor.stop()
        HotkeyManager.shared.setHotkeyCaptureActive(false)
        isRecordingHotkey = false
        if let message {
            hotkeyCaptureMessage = message
            hotkeyCaptureMessageIsError = isError
        }
    }
}

struct PermissionBadge: View {
    let granted: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
            Text(granted ? "已授權" : "未授權")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Model Row

struct ModelRow: View {
    let model: MLXModel
    let isSelected: Bool
    let isCached: Bool
    let readinessText: String
    let sizeString: String
    let isDownloading: Bool
    let downloadStatusText: String
    let anyDownloading: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Left: name + status badge + description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.id).font(.body.bold())
                    cacheStatusBadge
                }
                Text(model.description).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            // Right: action buttons + selected checkmark
            HStack(spacing: 6) {
                if model.id == "macos-speech" {
                    // No download needed — built into macOS
                    EmptyView()
                } else if !model.isLocal {
                    if isDownloading {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                            Text(downloadStatusText.isEmpty ? "下載中..." : downloadStatusText)
                                .font(.caption).foregroundColor(.orange)
                        }
                    } else if isCached {
                        Button(action: onDelete) {
                            Image(systemName: "trash").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("刪除本地快取")
                    } else {
                        Button(action: onDownload) {
                            Label("下載", systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(anyDownloading)
                    }
                }

                if isSelected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var cacheStatusBadge: some View {
        if model.isLocal {
            // macOS built-in — always ready, no badge needed
            EmptyView()
        } else if isDownloading {
            EmptyView()
        } else if isCached {
            badge(readinessText + (sizeString.isEmpty ? "" : " · " + sizeString), color: .green)
        } else {
            badge(readinessText, color: .secondary)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }
}

// MARK: - Model Tab

struct ModelSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var modelManager = ModelManager.shared
    @State private var dictionaryTerms: String = DictionaryService.shared.rawTerms
    @State private var deleteConfirmModelID: String?

    var body: some View {
        Form {
            Section("ASR 模型") {
                ForEach(AppState.availableModels) { model in
                    ModelRow(
                        model: model,
                        isSelected: appState.selectedModelID == model.id,
                        isCached: modelManager.isCached(model),
                        readinessText: modelManager.statusText(for: model),
                        sizeString: modelManager.sizeString(for: model),
                        isDownloading: modelManager.downloadingModelID == model.id,
                        downloadStatusText: modelManager.downloadStatusText,
                        anyDownloading: modelManager.downloadingModelID != nil,
                        onSelect: { appState.selectedModelID = model.id },
                        onDownload: { modelManager.download(model) },
                        onDelete: { deleteConfirmModelID = model.id }
                    )
                    .padding(.vertical, 2)
                }
            }
            .onAppear { modelManager.refreshAllStatuses() }
            .alert("刪除模型快取", isPresented: Binding(
                get: { deleteConfirmModelID != nil },
                set: { if !$0 { deleteConfirmModelID = nil } }
            )) {
                Button("取消", role: .cancel) { deleteConfirmModelID = nil }
                Button("刪除", role: .destructive) {
                    if let id = deleteConfirmModelID,
                       let model = AppState.availableModels.first(where: { $0.id == id }) {
                        try? modelManager.delete(model)
                    }
                    deleteConfirmModelID = nil
                }
            } message: {
                if let id = deleteConfirmModelID,
                   let model = AppState.availableModels.first(where: { $0.id == id }) {
                    Text("確定要刪除「\(model.id)」的本地快取嗎？下次使用時需要重新下載。")
                }
            }
            .alert("下載失敗", isPresented: Binding(
                get: { modelManager.downloadError != nil },
                set: { if !$0 { modelManager.downloadError = nil } }
            )) {
                Button("重試") {
                    if let errMsg = modelManager.downloadError,
                       let id = errMsg.components(separatedBy: "：").last,
                       let model = AppState.availableModels.first(where: { $0.id == id }) {
                        modelManager.downloadError = nil
                        modelManager.download(model)
                    }
                }
                Button("取消", role: .cancel) { modelManager.downloadError = nil }
            } message: {
                Text(modelManager.downloadError ?? "")
            }

            Section("語言") {
                Picker("辨識語言", selection: $appState.language) {
                    Text("自動偵測").tag("auto")
                    Text("中文（台灣）").tag("zh")
                    Text("英文").tag("en")
                    Text("日文").tag("ja")
                    Text("韓文").tag("ko")
                }
            }

            Section(header: Text("文字後處理"),
                    footer: Text("標點整理：只接受保留詞彙與數字的結果，需 macOS 26 + Apple Intelligence。\n移除猶豫詞：不需要 Apple Intelligence，所有 macOS 版本皆可使用，僅移除無語義的發音猶豫（呃、嗯、啊），不影響「那個」「就是」等詞彙。")) {
                Toggle("啟用標點整理", isOn: $appState.enableTextRefinement)
                    .onChange(of: appState.enableTextRefinement) { newValue in
                        if newValue, #available(macOS 26, *) {
                            Task { await TextRefiner.shared.warmUp() }
                        }
                    }
                Text("整理超過 10 秒或變更詞彙時，保留整理前文字。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("移除語音猶豫詞（呃、嗯、啊⋯）", isOn: $appState.removeFillers)
            }

            Section("人工錯詞對照") {
                Toggle("套用已確認的對照", isOn: $appState.enableVocabularyReplacements)
                VocabularyRulesView()
            }

            Section(header: Text("提示詞（Initial Prompt）"),
                    footer: Text("引導辨識結果的格式與語言風格，可留空")) {
                TextEditor(text: $appState.initialPrompt)
                    .font(.body)
                    .frame(height: 72)
                    .overlay(alignment: .topLeading) {
                        if appState.initialPrompt.isEmpty {
                            Text("例：以下是繁體中文的語音辨識結果。")
                                .foregroundColor(.secondary.opacity(0.6))
                                .font(.body)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                Text("提示詞與自訂詞典合計上限 600 字元，請只保留最關鍵的專名或語境。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section(header: Text("自訂詞典"),
                    footer: Text("一行一個詞，辨識時自動注入提示詞提升精度（例：專有名詞、品牌名稱、縮寫）。原生 macOS 語音路由最多使用 40 個詞，每詞最多 80 字元。")) {
                TextEditor(text: $dictionaryTerms)
                    .font(.body.monospaced())
                    .frame(height: 80)
                    .overlay(alignment: .topLeading) {
                        if dictionaryTerms.isEmpty {
                            Text("例：TypelessMLX\nBreeze-ASR")
                                .foregroundColor(.secondary.opacity(0.6))
                                .font(.body.monospaced())
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: dictionaryTerms) { newValue in
                        DictionaryService.shared.rawTerms = newValue
                    }
            }

            Section {
                Button("開啟設定與安裝視窗") {
                    SetupWindowController.shared.show()
                }
                .buttonStyle(.link)
                .help("安裝 Python 環境或重新轉換 Breeze-ASR-25")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History Tab

struct HistorySettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Stepper("保留 \(appState.maxHistoryCount) 筆記錄",
                        value: $appState.maxHistoryCount, in: 10...200, step: 10)
                Toggle("保存辨識失敗的錄音", isOn: $appState.retainFailedAudio)
                Text("只存在本機。上限 24 小時、10 筆或 200 MB。關閉會立即清除。")
                    .font(.caption).foregroundColor(.secondary)
                Button("立即清除救援錄音", role: .destructive) { appState.clearRecoveryAudio() }
                Button("清除所有歷史", role: .destructive) {
                    appState.clearHistory()
                }
            }

            Section("最近辨識") {
                if appState.history.isEmpty {
                    Text("尚無辨識記錄").foregroundColor(.secondary)
                } else {
                    ForEach(appState.history.prefix(20)) { entry in
                        HistoryEntryView(entry: entry).environmentObject(appState)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}


private struct HistoryEntryView: View {
    @EnvironmentObject var appState: AppState
    let entry: TranscriptionEntry
    @State private var editingRule = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text.isEmpty ? (entry.failureReason ?? "未取得文字") : entry.text)
                .lineLimit(3).textSelection(.enabled)
            Text(entry.delivery.description).font(.caption).foregroundColor(.secondary)
            if let reason = entry.failureReason { Text(reason).font(.caption).foregroundColor(.orange) }
            HStack {
                Text(entry.timestamp, style: .relative)
                Text("• \(String(format: "%.1fs", entry.duration)) • \(entry.model)")
                if let gain = entry.gainDB { Text("• \(Int(gain)) dB") }
            }.font(.caption).foregroundColor(.secondary)
            HStack {
                if !entry.text.isEmpty {
                    Button("複製") { appState.copyHistory(entry.id) }
                    Button("複製原文") { appState.copyHistory(entry.id, original: true) }
                    Button("還原原文") { appState.restoreOriginal(entry.id) }
                    Button("建立錯詞對照") { editingRule = true }
                }
                if let recovery = entry.recoveryID, appState.recoveryStore?.url(for: recovery) != nil {
                    Button("重試錄音") { HotkeyManager.shared.retryHistory(entry) }
                        .disabled(appState.status != .idle)
                }
            }.controlSize(.small)
            if !entry.originalText.isEmpty {
                DisclosureGroup("原文與整理結果") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("原文：" + entry.originalText)
                        if let text = entry.substitutedText { Text("詞彙替換：" + text) }
                        if let text = entry.refinedText { Text("標點整理：" + text) }
                    }.textSelection(.enabled).font(.caption)
                }
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $editingRule) { VocabularyRuleEditor(source: entry) }
    }
}

private struct VocabularyRulesView: View {
    @State private var rules = DictionaryService.shared.correctionRules
    @State private var canUndo = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rules.isEmpty { Text("從歷史按「建立錯詞對照」新增。") .font(.caption).foregroundColor(.secondary) }
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Toggle(rule.wrong + " → " + rule.right, isOn: Binding(
                            get: { rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
                            set: { value in
                                _ = DictionaryService.shared.setReplacementEnabled(id: rule.id, enabled: value)
                                refresh()
                            }
                        ))
                        Button("刪除", role: .destructive) {
                            _ = DictionaryService.shared.deleteReplacement(id: rule.id)
                            canUndo = true
                            refresh()
                        }.controlSize(.small)
                    }
                    Text("來源歷史：" + rule.sourceHistoryID.uuidString.prefix(8))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Button("撤銷上次刪除") {
                _ = DictionaryService.shared.undoLastReplacementDeletion()
                refresh()
            }
            .disabled(!canUndo)
            Text("英文比對不分大小寫。中文只套用已確認的對照。每段原文只替換一次。")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { refresh(); canUndo = true }
    }
    private func refresh() { rules = DictionaryService.shared.correctionRules }
}

private struct VocabularyRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let source: TranscriptionEntry
    @State private var wrong = ""
    @State private var right = ""
    @State private var confirmed = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("建立錯詞對照").font(.headline)
            Text(source.originalText).lineLimit(5).textSelection(.enabled)
            TextField("辨識錯詞", text: $wrong)
            TextField("正確詞彙", text: $right)
            Toggle("我已確認詞彙及中文套用位置", isOn: $confirmed)
            Text("中文會比對所有符合片段。請確認這組對照不會改錯其他詞。")
                .font(.caption).foregroundColor(.secondary)
            if let error { Text(error).foregroundColor(.red).font(.caption) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("儲存") {
                    guard DictionaryService.shared.addReplacement(wrong: wrong, right: right,
                        sourceHistoryID: source.id, chineseBoundaryConfirmed: confirmed) != nil else {
                        error = "請輸入有效詞彙，並確認中文套用位置。"
                        return
                    }
                    dismiss()
                }.disabled(!confirmed)
            }
        }.padding(20).frame(width: 440)
    }
}
