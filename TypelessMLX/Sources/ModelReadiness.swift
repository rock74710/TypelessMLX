import Foundation

enum ModelReadinessStatus: Equatable {
    case notInstalled
    case downloading
    case validating
    case ready
    case needsRepair
    case unavailable(String)
}

enum ModelReadinessError: LocalizedError, Equatable {
    case unavailable(String)
    case busy
    case cancelled
    case backend(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .backend(let message): return message
        case .busy: return "模型準備已在執行中。"
        case .cancelled: return "模型準備已取消。"
        case .malformedResponse: return "模型準備程序回傳了無效狀態。"
        }
    }
}

struct ModelReadinessCommandResult: Decodable {
    let status: String
    let modelID: String?
    let path: String?
    let size: Int64?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case modelID = "model_id"
        case path
        case size
        case message
    }
}

enum ModelReadiness {
    private static let readyMarkerName = ".typelessmlx-model-ready.json"

    /// Checks the Python-written marker without importing or loading a model.
    static func isReady(directoryURL: URL, modelID: String) -> Bool {
        if modelID == "macos-speech" { return true }
        guard let marker = readMarker(directoryURL: directoryURL) else { return false }
        guard marker["status"] as? String == "ready",
              marker["model_id"] as? String == modelID,
              let loader = marker["loader"] as? String,
              !loader.isEmpty,
              let revision = marker["revision"] as? String,
              let requiredFiles = marker["required_files"] as? [String],
              let fingerprint = marker["fingerprint"] as? [[String: Any]] else {
            return false
        }

        guard let expected = expectedMarkerSpec(modelID: modelID, revision: revision),
              expected.requiredFiles == requiredFiles.sorted(),
              !requiredFiles.isEmpty else {
            return false
        }

        let modelURL = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard let markerPath = marker["model_path"] as? String,
              sameDirectory(markerPath, modelURL) else {
            return false
        }
        let fingerprintPaths = fingerprint.compactMap { $0["path"] as? String }
        guard fingerprint.count == requiredFiles.count,
              fingerprintPaths.count == fingerprint.count,
              Set(fingerprintPaths).count == fingerprintPaths.count,
              Set(fingerprintPaths) == Set(requiredFiles) else {
            return false
        }

        for entry in fingerprint {
            guard let relativePath = entry["path"] as? String,
                  isSafeRelativePath(relativePath),
                  let expectedSize = (entry["size"] as? NSNumber)?.int64Value,
                  let expectedMTime = (entry["mtime_ms"] as? NSNumber)?.int64Value,
                  let expectedInode = (entry["inode"] as? NSNumber)?.uint64Value,
                  let expectedDevice = (entry["device"] as? NSNumber)?.uint64Value else {
                return false
            }

            let fileURL = modelURL
                .appendingPathComponent(relativePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let fileType = attributes[.type] as? FileAttributeType,
                  fileType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value else {
                return false
            }
            let modifiedMilliseconds = Int64((modified.timeIntervalSince1970 * 1_000).rounded(.down))
            guard size == expectedSize,
                  modifiedMilliseconds == expectedMTime,
                  inode == expectedInode,
                  device == expectedDevice else {
                return false
            }
        }
        return true
    }

    static func statusText(for status: ModelReadinessStatus) -> String {
        switch status {
        case .notInstalled: return "尚未安裝"
        case .downloading: return "下載中…"
        case .validating: return "驗證中…"
        case .ready: return "可用"
        case .needsRepair: return "需要修復"
        case .unavailable(let message): return message
        }
    }

    static func runBackendCommand(
        modelID: String,
        prepare: Bool,
        onProcessStarted: ((Process) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) throws -> ModelReadinessCommandResult {
        guard WhisperBridge.isVenvReady() else {
            throw ModelReadinessError.unavailable("Python 環境尚未安裝。")
        }
        let script = WhisperBridge.shared.scriptPath
        guard FileManager.default.fileExists(atPath: script) else {
            throw ModelReadinessError.unavailable("找不到 Python 語音後端。")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: WhisperBridge.shared.pythonPath)
        process.arguments = ["-u", script, prepare ? "--prepare-model" : "--check-model", modelID]
        process.environment = WhisperBridge.makeEnv()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                onLog?(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw ModelReadinessError.backend("無法啟動模型準備程序：\(error.localizedDescription)")
        }
        onProcessStarted?(process)
        process.waitUntilExit()
        errorPipe.fileHandleForReading.readabilityHandler = nil
        let response = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: response, encoding: .utf8),
              let responseLine = text.split(whereSeparator: \.isNewline).last,
              let data = String(responseLine).data(using: .utf8),
              let result = try? JSONDecoder().decode(ModelReadinessCommandResult.self, from: data) else {
            throw ModelReadinessError.malformedResponse
        }
        if process.terminationStatus != 0 || result.status == "error" {
            throw ModelReadinessError.backend(result.message ?? "模型完整性檢查失敗。")
        }
        return result
    }

    private static func readMarker(directoryURL: URL) -> [String: Any]? {
        let root = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        let markerURL = root.appendingPathComponent(readyMarkerName)
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (marker["schema_version"] as? NSNumber)?.intValue == 1 else {
            return nil
        }
        return marker
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    private static func sameDirectory(_ recordedPath: String, _ requestedURL: URL) -> Bool {
        guard recordedPath.hasPrefix("/") else { return false }
        let recordedURL = URL(fileURLWithPath: recordedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let requestedURL = requestedURL.resolvingSymlinksInPath().standardizedFileURL
        guard let recordedAttributes = try? FileManager.default.attributesOfItem(atPath: recordedURL.path),
              let requestedAttributes = try? FileManager.default.attributesOfItem(atPath: requestedURL.path),
              let recordedType = recordedAttributes[.type] as? FileAttributeType,
              let requestedType = requestedAttributes[.type] as? FileAttributeType,
              recordedType == .typeDirectory,
              requestedType == .typeDirectory,
              let recordedInode = (recordedAttributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let requestedInode = (requestedAttributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let recordedDevice = (recordedAttributes[.systemNumber] as? NSNumber)?.uint64Value,
              let requestedDevice = (requestedAttributes[.systemNumber] as? NSNumber)?.uint64Value else {
            return false
        }
        return recordedInode == requestedInode && recordedDevice == requestedDevice
    }

    private static func expectedMarkerSpec(
        modelID: String,
        revision: String
    ) -> (requiredFiles: [String], revision: String)? {
        guard let manifest = readManifest(),
              let models = manifest["models"] as? [String: Any],
              let spec = models[modelID] as? [String: Any],
              let remoteRevision = spec["revision"] as? String,
              let requiredFiles = spec["required_files"] as? [String: Any] else {
            return nil
        }

        if modelID == "breeze-asr-25",
           let sources = manifest["conversion_sources"] as? [String: Any],
           let source = sources["breeze-asr-25-canonical"] as? [String: Any],
           let sourceRevision = source["revision"] as? String {
            if revision == "local:breeze-8bit:\(remoteRevision)" {
                return (["config.json", "quantization_manifest.json", "weights.safetensors"].sorted(), revision)
            }
            if revision == "local:breeze-fp16:\(sourceRevision)" {
                return (["config.json", "conversion_manifest.json", "weights.safetensors"].sorted(), revision)
            }
        }

        guard revision == remoteRevision else { return nil }
        return (requiredFiles.keys.sorted(), remoteRevision)
    }

    private static func readManifest() -> [String: Any]? {
        if let bundleURL = Bundle.main.url(
            forResource: "model_manifest",
            withExtension: "json",
            subdirectory: "backend"
        ), let data = try? Data(contentsOf: bundleURL),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return manifest
        }

        let projectURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend/model_manifest.json")
        guard let data = try? Data(contentsOf: projectURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return manifest
    }
}
