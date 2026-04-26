import SwiftUI
import Combine
import AVFoundation

enum AppStatus: String {
    case idle = "待機中"
    case recording = "錄音中..."
    case transcribing = "辨識中..."
}

enum PermissionState: String {
    case ready = "🟢 就緒"
    case missingPermissions = "🟡 缺少權限"
    case error = "🔴 錯誤"
}

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let duration: TimeInterval
    let model: String

    init(text: String, duration: TimeInterval, model: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.duration = duration
        self.model = model
    }
}

// MLX model definitions
struct MLXModel: Identifiable {
    let id: String          // display name / storage key
    let repoOrPath: String  // HuggingFace repo or local path (resolved at runtime)
    let description: String
    var isLocal: Bool       // true = local converted model, false = HF repo
    var modelType: String   // "whisper" | "qwen3"
}

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var status: AppStatus = .idle {
        didSet { logInfo("AppState", "Status: \(oldValue.rawValue) → \(status.rawValue)") }
    }
    @Published var errorMessage: String?
    @Published var history: [TranscriptionEntry] = []
    @Published var permissionState: PermissionState = .missingPermissions
    @Published var hasMicPermission: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    @Published var hasPythonBackend: Bool = false

    // Settings (persisted via AppStorage)
    @AppStorage("selectedModelID") var selectedModelID: String = "macos-speech"
    @AppStorage("showFloatingOverlay") var showFloatingOverlay: Bool = true
    @AppStorage("playSounds") var playSounds: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hotkeyKeyCode") var hotkeyKeyCode: Int = RecognitionHotkey.defaultKeyCode
    @AppStorage("language") var language: String = "auto"
    @AppStorage("hotkeyMode") var hotkeyMode: String = "toggle"  // "toggle" or "hold"
    @AppStorage("maxHistoryCount") var maxHistoryCount: Int = 50
    @AppStorage("initialPrompt") var initialPrompt: String = ""
    @AppStorage("inputDeviceUID") var inputDeviceUID: String = ""  // empty = system default
    @AppStorage("enableTextRefinement") var enableTextRefinement: Bool = true
    @AppStorage("removeFillers") var removeFillers: Bool = false
    // Live transcription text (set by WhisperBridge progress callbacks)
    @Published var liveTranscriptionConfirmedText: String = ""
    @Published var liveTranscriptionUnconfirmedText: String = ""

    // Available MLX models
    static let availableModels: [MLXModel] = [
        MLXModel(
            id: "macos-speech",
            repoOrPath: "",
            description: "macOS 內建語音辨識（快速、不需下載、不需 Python）",
            isLocal: true, modelType: "macos"
        ),
        MLXModel(
            id: "qwen3-asr-0.6b",
            repoOrPath: "mlx-community/Qwen3-ASR-0.6B-8bit",
            description: "Qwen3-ASR 0.6B（中文精度最佳，~1GB，推薦）",
            isLocal: false, modelType: "qwen3"
        ),
        MLXModel(
            id: "breeze-asr-25",
            repoOrPath: "schsu/breeze-asr-25-mlx",
            description: "Breeze-ASR-25（台灣中文優化，MediaTek Research，~1.8GB）",
            isLocal: false, modelType: "whisper"
        ),
        MLXModel(
            id: "whisper-large-v3",
            repoOrPath: "mlx-community/whisper-large-v3-mlx",
            description: "Whisper Large v3（多語言，3.1GB，最高精度）",
            isLocal: false, modelType: "whisper"
        ),
        MLXModel(
            id: "whisper-medium",
            repoOrPath: "mlx-community/whisper-medium-mlx",
            description: "Whisper Medium（多語言，1.5GB）",
            isLocal: false, modelType: "whisper"
        ),
        MLXModel(
            id: "whisper-small",
            repoOrPath: "mlx-community/whisper-small-mlx",
            description: "Whisper Small（465MB，最快）",
            isLocal: false, modelType: "whisper"
        ),
    ]

    var selectedModel: MLXModel {
        Self.availableModels.first { $0.id == selectedModelID } ?? Self.availableModels[0]
    }

    var recognitionHotkey: RecognitionHotkey {
        RecognitionHotkey.resolve(keyCode: hotkeyKeyCode)
    }

    var hotkeyDisplayName: String {
        recognitionHotkey.displayName
    }

    func setRecognitionHotkey(_ hotkey: RecognitionHotkey) {
        guard hotkeyKeyCode != hotkey.keyCode else { return }
        objectWillChange.send()
        hotkeyKeyCode = hotkey.keyCode
    }

    /// Resolved model path or HF repo for Python backend
    var resolvedModelPath: String {
        let model = selectedModel
        if model.isLocal {
            // Check if local conversion exists; if not, fall back to whisper-large-v3
            if FileManager.default.fileExists(atPath: model.repoOrPath) {
                return model.repoOrPath
            } else {
                logWarn("AppState", "Breeze-ASR-25 local model not found, falling back to whisper-large-v3")
                return "mlx-community/whisper-large-v3-mlx"
            }
        }
        return model.repoOrPath
    }

    private init() {
        loadHistory()
        logInfo("AppState", "Initialized. Model=\(selectedModelID), Language=\(language), Mode=\(hotkeyMode)")
    }

    func setStatus(_ newStatus: AppStatus) {
        if Thread.isMainThread {
            self.status = newStatus
        } else {
            DispatchQueue.main.async { self.status = newStatus }
        }
    }

    func showError(_ message: String) {
        logError("AppState", "Error: \(message)")
        if Thread.isMainThread {
            self.errorMessage = message
        } else {
            DispatchQueue.main.async { self.errorMessage = message }
        }
    }

    func updatePermissionState() {
        if hasMicPermission && hasAccessibilityPermission && hasPythonBackend {
            permissionState = .ready
        } else if !hasMicPermission || !hasAccessibilityPermission {
            permissionState = .missingPermissions
        } else {
            permissionState = .error
        }
        logInfo("AppState", "Permission state: \(permissionState.rawValue) [mic=\(hasMicPermission) ax=\(hasAccessibilityPermission) python=\(hasPythonBackend)]")
    }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.hasMicPermission = mic
            self.hasAccessibilityPermission = ax
            self.updatePermissionState()
        }
    }

    func addToHistory(_ entry: TranscriptionEntry) {
        let work = {
            self.history.insert(entry, at: 0)
            if self.history.count > self.maxHistoryCount {
                self.history = Array(self.history.prefix(self.maxHistoryCount))
            }
            self.saveHistory()
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async { work() } }
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private var historyURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/typelessmlx")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: historyURL)
        } catch {
            logError("AppState", "Failed to save history: \(error)")
        }
    }

    private func loadHistory() {
        do {
            let data = try Data(contentsOf: historyURL)
            history = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
            logInfo("AppState", "Loaded \(history.count) history entries")
        } catch {
            logDebug("AppState", "No history: \(error.localizedDescription)")
        }
    }
}
