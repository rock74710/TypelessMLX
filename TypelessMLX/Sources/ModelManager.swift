import Foundation

/// Manages on-disk cache for MLX models (HuggingFace Hub + local converted models).
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var downloadingModelID: String?
    @Published var downloadStatusText: String = ""     // e.g. "下載中 7/11 個檔案..."
    @Published var downloadError: String? = nil
    @Published var cachedSizes: [String: Int64] = [:]  // modelID → bytes, 0 = not cached

    private var downloadProcess: Process?
    private let queue = DispatchQueue(label: "com.typelessmlx.modelmanager", qos: .utility)

    private init() {
        refreshAllStatuses()
    }

    // MARK: - Cache Status

    func refreshAllStatuses() {
        queue.async { [weak self] in
            guard let self = self else { return }
            var sizes: [String: Int64] = [:]
            for model in AppState.availableModels {
                sizes[model.id] = self.diskSize(for: model)
            }
            DispatchQueue.main.async { self.cachedSizes = sizes }
        }
    }

    func isCached(_ model: MLXModel) -> Bool {
        (cachedSizes[model.id] ?? 0) > 0
    }

    /// Human-readable size string, e.g. "1.2 GB"
    func sizeString(for model: MLXModel) -> String {
        let bytes = cachedSizes[model.id] ?? 0
        guard bytes > 0 else { return "" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 0.1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Download

    func download(_ model: MLXModel) {
        guard downloadingModelID == nil else { return }
        guard !model.isLocal else { return }  // local models (breeze) use SetupWindowController

        DispatchQueue.main.async {
            self.downloadingModelID = model.id
            self.downloadStatusText = "連線中..."
            self.downloadError = nil
        }
        logInfo("ModelManager", "Starting download: \(model.repoOrPath)")

        queue.async { [weak self] in
            guard let self = self else { return }
            let python = WhisperBridge.shared.pythonPath
            let script = """
import sys, os
os.environ['HF_HOME'] = os.path.expanduser('~/.cache/huggingface')
from huggingface_hub import snapshot_download
snapshot_download('\(model.repoOrPath)')
print('DONE')
sys.stdout.flush()
"""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = ["-c", script]
            proc.environment = WhisperBridge.makeEnv()

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    logDebug("ModelManager", text)
                    // Parse "Fetching N files: X%|..." progress from huggingface_hub
                    if text.contains("Fetching") || text.contains("Downloading") {
                        let status: String
                        if let range = text.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
                            status = "下載中 \(text[range]) 個檔案..."
                        } else if text.contains("%") {
                            status = "下載中..."
                        } else {
                            status = "下載中..."
                        }
                        DispatchQueue.main.async { self?.downloadStatusText = status }
                    }
                }
            }

            self.downloadProcess = proc
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                logError("ModelManager", "Download process error: \(error)")
            }

            errPipe.fileHandleForReading.readabilityHandler = nil
            let success = proc.terminationStatus == 0
            logInfo("ModelManager", "Download \(success ? "succeeded" : "failed") for \(model.id)")

            // Compute disk size on background thread to avoid blocking main thread
            let size = self.diskSize(for: model)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.downloadingModelID = nil
                self.downloadStatusText = ""
                self.downloadProcess = nil
                self.cachedSizes[model.id] = size
                self.downloadError = success ? nil : "下載失敗：\(model.id)"
            }
        }
    }

    func cancelDownload() {
        downloadProcess?.terminate()
        downloadProcess = nil
        DispatchQueue.main.async {
            self.downloadingModelID = nil
            self.downloadError = nil
        }
    }

    // MARK: - Delete

    func delete(_ model: MLXModel) throws {
        guard let cacheURL = cacheDirectory(for: model) else { return }
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
            logInfo("ModelManager", "Deleted cache: \(cacheURL.lastPathComponent)")
        }
        DispatchQueue.main.async { self.cachedSizes[model.id] = 0 }
    }

    // MARK: - Paths

    /// Returns the root cache directory for the model (nil if not applicable).
    private func cacheDirectory(for model: MLXModel) -> URL? {
        // Breeze keeps a stable model ID while preferring the validated local
        // 8-bit artifact. Report and delete the artifact the app will actually
        // load, then fall back through the legacy FP16 directory to HF cache.
        if model.id == AppState.breezeModelID {
            if AppState.isUsableModelDirectory(AppState.breeze8BitModelURL) {
                return AppState.breeze8BitModelURL
            }
            if AppState.isUsableModelDirectory(AppState.breezeFP16ModelURL) {
                return AppState.breezeFP16ModelURL
            }
        }
        if model.isLocal {
            return URL(fileURLWithPath: model.repoOrPath)
        }
        // HuggingFace Hub format: models--org--repo
        let sanitized = model.repoOrPath.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)")
    }

    private func diskSize(for model: MLXModel) -> Int64 {
        guard let dir = cacheDirectory(for: model) else { return 0 }
        let isResolvedBreezeLocalArtifact = model.id == AppState.breezeModelID
            && (dir == AppState.breeze8BitModelURL || dir == AppState.breezeFP16ModelURL)
        if model.isLocal || isResolvedBreezeLocalArtifact {
            guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
            return directorySize(dir)
        }
        // HF Hub stores actual files in blobs/ (snapshots/ only has symlinks)
        let blobs = dir.appendingPathComponent("blobs")
        guard FileManager.default.fileExists(atPath: blobs.path) else { return 0 }
        let size = directorySize(blobs)
        return size > 1024 ? size : 0
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
