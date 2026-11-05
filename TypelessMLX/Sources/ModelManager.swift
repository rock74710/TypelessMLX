import Foundation
import Combine

/// Manages fixed-revision model downloads and readiness checks.
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var downloadingModelID: String?
    @Published var downloadStatusText: String = ""
    @Published var downloadError: String?
    @Published var cachedSizes: [String: Int64] = [:]
    @Published private(set) var readinessStates: [String: ModelReadinessStatus] = [:]

    private final class PreparationOperation {
        let id = UUID()
        let model: MLXModel
        let previousState: ModelReadinessStatus
        let completion: (Result<String, ModelReadinessError>) -> Void
        var process: Process?
        var finished = false

        init(
            model: MLXModel,
            previousState: ModelReadinessStatus,
            completion: @escaping (Result<String, ModelReadinessError>) -> Void
        ) {
            self.model = model
            self.previousState = previousState
            self.completion = completion
        }
    }

    private let queue = DispatchQueue(label: "com.typelessmlx.modelmanager", qos: .utility)
    private let operationLock = NSLock()
    private var activeOperation: PreparationOperation?

    private init() {
        refreshAllStatuses()
    }

    // MARK: - Readiness

    func refreshAllStatuses(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            var states: [String: ModelReadinessStatus] = [:]
            var sizes: [String: Int64] = [:]

            for model in AppState.availableModels {
                if model.modelType == "macos" {
                    states[model.id] = .ready
                    sizes[model.id] = 0
                    continue
                }

                guard WhisperBridge.isVenvReady() else {
                    states[model.id] = .unavailable("Python 環境尚未安裝")
                    sizes[model.id] = 0
                    continue
                }

                do {
                    let result = try ModelReadiness.runBackendCommand(
                        modelID: model.id,
                        prepare: false
                    )
                    let state: ModelReadinessStatus
                    switch result.status {
                    case "ready":
                        if let path = result.path, !path.isEmpty,
                           ModelReadiness.isReady(
                            directoryURL: URL(fileURLWithPath: path),
                            modelID: model.id
                           ) {
                            state = .ready
                        } else {
                            state = .needsRepair
                        }
                    case "needs_repair": state = .needsRepair
                    case "not_installed": state = .notInstalled
                    default: state = .unavailable(result.message ?? "無法檢查模型")
                    }
                    states[model.id] = state
                    sizes[model.id] = result.size ?? 0
                } catch {
                    states[model.id] = .unavailable(error.localizedDescription)
                    sizes[model.id] = 0
                }
            }

            DispatchQueue.main.async {
                self.operationLock.lock()
                let activeModelID = self.activeOperation?.model.id
                self.operationLock.unlock()
                for (modelID, state) in states where modelID != activeModelID {
                    self.readinessStates[modelID] = state
                    self.cachedSizes[modelID] = sizes[modelID] ?? 0
                }
                completion?()
            }
        }
    }

    func readinessState(for model: MLXModel) -> ModelReadinessStatus {
        if model.modelType == "macos" { return .ready }
        return readinessStates[model.id] ?? .notInstalled
    }

    func isReady(for model: MLXModel) -> Bool {
        if model.modelType == "macos" { return true }
        if case .ready = readinessState(for: model) { return true }
        return false
    }

    func isCached(_ model: MLXModel) -> Bool {
        isReady(for: model)
    }

    func statusText(for model: MLXModel) -> String {
        ModelReadiness.statusText(for: readinessState(for: model))
    }

    /// Prepares the model before recording and returns the validated local path.
    func prepare(
        _ model: MLXModel,
        completion: @escaping (Result<String, ModelReadinessError>) -> Void
    ) {
        if model.modelType == "macos" {
            DispatchQueue.main.async { completion(.success("")) }
            return
        }

        operationLock.lock()
        guard activeOperation == nil else {
            operationLock.unlock()
            DispatchQueue.main.async { completion(.failure(.busy)) }
            return
        }
        let operation = PreparationOperation(
            model: model,
            previousState: readinessStates[model.id] ?? .notInstalled,
            completion: completion
        )
        activeOperation = operation
        operationLock.unlock()

        DispatchQueue.main.async {
            self.readinessStates[model.id] = .validating
            self.downloadingModelID = model.id
            self.downloadStatusText = "驗證中…"
            self.downloadError = nil
        }

        queue.async { [weak self, weak operation] in
            guard let self, let operation, self.isActive(operation) else { return }
            do {
                let response = try ModelReadiness.runBackendCommand(
                    modelID: model.id,
                    prepare: true,
                    onProcessStarted: { [weak self, weak operation] process in
                        guard let self, let operation else { process.terminate(); return }
                        self.attach(process: process, to: operation)
                    },
                    onLog: { [weak self, weak operation] line in
                        guard let self, let operation else { return }
                        self.recordProgress(line, for: operation)
                    }
                )
                guard response.status == "ready",
                      let path = response.path else {
                    throw ModelReadinessError.malformedResponse
                }
                if !path.isEmpty,
                   !ModelReadiness.isReady(
                    directoryURL: URL(fileURLWithPath: path),
                    modelID: model.id
                   ) {
                    throw ModelReadinessError.backend("Python 與 App 的模型指紋檢查不一致。")
                }
                self.finish(operation, result: .success(path), size: response.size)
            } catch let error as ModelReadinessError {
                self.finish(operation, result: .failure(error), size: nil)
            } catch {
                self.finish(
                    operation,
                    result: .failure(.backend(error.localizedDescription)),
                    size: nil
                )
            }
        }
    }

    // MARK: - Download

    func download(_ model: MLXModel) {
        guard model.modelType != "macos" else { return }
        guard downloadingModelID == nil else { return }
        prepare(model) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result, error != .cancelled {
                self.downloadError = "下載失敗：\(model.id)"
                logError("ModelManager", "Prepare failed for \(model.id): \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload() {
        operationLock.lock()
        guard let operation = activeOperation, !operation.finished else {
            operationLock.unlock()
            return
        }
        operation.finished = true
        activeOperation = nil
        let process = operation.process
        operationLock.unlock()

        process?.terminate()
        DispatchQueue.main.async {
            self.readinessStates[operation.model.id] = operation.previousState
            self.downloadingModelID = nil
            self.downloadStatusText = ""
            operation.completion(.failure(.cancelled))
        }
    }

    // MARK: - Delete

    func delete(_ model: MLXModel) throws {
        guard let cacheURL = cacheDirectory(for: model) else { return }
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
            logInfo("ModelManager", "Deleted cache: \(cacheURL.lastPathComponent)")
        }
        DispatchQueue.main.async {
            self.cachedSizes[model.id] = 0
            self.readinessStates[model.id] = .notInstalled
        }
    }

    // MARK: - Paths and display

    /// Human-readable size string, e.g. "1.2 GB".
    func sizeString(for model: MLXModel) -> String {
        let bytes = cachedSizes[model.id] ?? 0
        guard bytes > 0 else { return "" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 0.1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    private func cacheDirectory(for model: MLXModel) -> URL? {
        if model.id == AppState.breezeModelID {
            for url in [AppState.breeze8BitModelURL, AppState.breezeFP16ModelURL]
            where FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if model.isLocal {
            return URL(fileURLWithPath: model.repoOrPath)
        }
        let sanitized = model.repoOrPath.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)")
    }

    private func attach(process: Process, to operation: PreparationOperation) {
        operationLock.lock()
        guard activeOperation?.id == operation.id, !operation.finished else {
            operationLock.unlock()
            process.terminate()
            return
        }
        operation.process = process
        operationLock.unlock()
    }

    private func recordProgress(_ line: String, for operation: PreparationOperation) {
        guard isActive(operation) else { return }
        let bounded = String(line.suffix(300))
        let nextState: ModelReadinessStatus = line.localizedCaseInsensitiveContains("Downloading")
            || line.localizedCaseInsensitiveContains("Fetching")
            ? .downloading : .validating
        DispatchQueue.main.async {
            guard self.isActive(operation) else { return }
            self.readinessStates[operation.model.id] = nextState
            self.downloadStatusText = bounded.isEmpty
                ? ModelReadiness.statusText(for: nextState)
                : bounded
        }
    }

    private func isActive(_ operation: PreparationOperation) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return activeOperation?.id == operation.id && !operation.finished
    }

    private func finish(
        _ operation: PreparationOperation,
        result: Result<String, ModelReadinessError>,
        size: Int64?
    ) {
        operationLock.lock()
        guard activeOperation?.id == operation.id, !operation.finished else {
            operationLock.unlock()
            return
        }
        operation.finished = true
        activeOperation = nil
        operationLock.unlock()

        DispatchQueue.main.async {
            switch result {
            case .success:
                self.readinessStates[operation.model.id] = .ready
                self.cachedSizes[operation.model.id] = size ?? 0
                self.downloadStatusText = ""
            case .failure(let error):
                if error == .cancelled {
                    self.readinessStates[operation.model.id] = operation.previousState
                } else if case .unavailable(let message) = error {
                    self.readinessStates[operation.model.id] = .unavailable(message)
                } else {
                    self.readinessStates[operation.model.id] = .needsRepair
                    self.downloadStatusText = ""
                }
            }
            self.downloadingModelID = nil
            operation.completion(result)
        }
    }
}
