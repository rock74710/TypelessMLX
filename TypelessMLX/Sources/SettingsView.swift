import SwiftUI
import AVFoundation
import ServiceManagement

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
        .frame(width: 480, height: 420)
        .padding()
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var inputDevices: [(name: String, uid: String)] = []

    var body: some View {
        Form {
            Section("快捷鍵") {
                HStack {
                    Text("辨識快捷鍵")
                    Spacer()
                    Menu {
                        ForEach(RecognitionHotkey.all) { hotkey in
                            Button {
                                selectHotkey(hotkey)
                            } label: {
                                if appState.recognitionHotkey == hotkey {
                                    Label(hotkey.displayName, systemImage: "checkmark")
                                } else {
                                    Text(hotkey.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard")
                            Text(appState.hotkeyDisplayName)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .frame(minWidth: 160, alignment: .trailing)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                HStack {
                    Text("Python 後端")
                    Spacer()
                    PermissionBadge(granted: appState.hasPythonBackend)
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
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (build \(build))"
    }

    private func selectHotkey(_ hotkey: RecognitionHotkey) {
        appState.setRecognitionHotkey(hotkey)
        HotkeyManager.shared.refreshMonitors()
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
            badge(sizeString.isEmpty ? "已下載" : sizeString, color: .green)
        } else {
            badge("未下載", color: .secondary)
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
                    footer: Text("文字修正：使用 Apple Foundation Models 修正標點與錯字，需 macOS 26 + Apple Intelligence。\n移除猶豫詞：不需要 Apple Intelligence，所有 macOS 版本皆可使用，僅移除無語義的發音猶豫（呃、嗯、啊），不影響「那個」「就是」等詞彙。")) {
                Toggle("啟用文字修正", isOn: $appState.enableTextRefinement)
                    .onChange(of: appState.enableTextRefinement) { newValue in
                        if newValue, #available(macOS 26, *) {
                            Task { await TextRefiner.shared.warmUp() }
                        }
                    }
                Text("預設關閉可省下數百毫秒，僅在需要標點修正時再開啟。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("移除語音猶豫詞（呃、嗯、啊⋯）", isOn: $appState.removeFillers)
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
                    footer: Text("一行一個詞，辨識時自動注入提示詞提升精度（例：專有名詞、品牌名稱、縮寫）")) {
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
                Button("清除所有歷史", role: .destructive) {
                    appState.clearHistory()
                }
            }

            Section("最近辨識") {
                if appState.history.isEmpty {
                    Text("尚無辨識記錄").foregroundColor(.secondary)
                } else {
                    List(appState.history.prefix(20)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text).lineLimit(2).font(.body)
                            HStack {
                                Text(entry.timestamp, style: .relative)
                                Text("• \(String(format: "%.1fs", entry.duration))")
                                Text("• \(entry.model)")
                            }
                            .font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
