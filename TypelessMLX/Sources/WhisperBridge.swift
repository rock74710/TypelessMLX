import Foundation
import AVFoundation

/// Manages the persistent Python mlx-whisper subprocess.
/// Communicates via newline-delimited JSON over stdin/stdout (JSON-RPC style).
class WhisperBridge {
    static let shared = WhisperBridge()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var isReady = false
    private var startupToken: UUID?
    private struct RequestContext {
        let completion: (Result<String, Error>) -> Void
        let startTime: Date
        let timeoutItem: DispatchWorkItem
        let label: String
    }
    private var pendingRequests: [String: RequestContext] = [:]
    private let lock = NSLock()
    private var readBuffer = ""
    private var pingTimer: Timer?
    private var idleTimer: Timer?


    private let pythonOverride: String?
    private let scriptOverride: String?
    private let requestTimeout: TimeInterval
    init(python: String? = nil, script: String? = nil, timeout: TimeInterval = 120) {
        pythonOverride = python; scriptOverride = script; requestTimeout = timeout
    }

    var backendIsReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReady && process?.isRunning == true
    }

    // MARK: - Paths

    var pythonPath: String {
        if let pythonOverride { return pythonOverride }
        let venvPython = NSHomeDirectory() + "/.local/share/typelessmlx/venv/bin/python"
        if FileManager.default.fileExists(atPath: venvPython) { return venvPython }
        // Homebrew fallbacks
        for path in ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "python3"
    }

    var scriptPath: String {
        if let scriptOverride { return scriptOverride }
        // In app bundle (Resources/backend/transcribe_server.py)
        if let path = Bundle.main.path(forResource: "transcribe_server", ofType: "py", inDirectory: "backend") {
            return path
        }
        // Development: relative to this source file
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // TypelessMLX/
            .deletingLastPathComponent() // project root
        return projectRoot.appendingPathComponent("backend/transcribe_server.py").path
    }

    static func isVenvReady() -> Bool {
        let python = NSHomeDirectory() + "/.local/share/typelessmlx/venv/bin/python"
        return FileManager.default.fileExists(atPath: python)
    }

    // MARK: - Lifecycle

    func start(completion: @escaping (Bool) -> Void) {
        stopProcess()
        let token = UUID()
        lock.lock(); startupToken = token; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.startProcess(token: token, completion: completion)
        }
    }

    private func startProcess(token: UUID, completion: @escaping (Bool) -> Void) {
        lock.lock()
        let current = startupToken == token
        lock.unlock()
        guard current else { DispatchQueue.main.async { completion(false) }; return }

        let python = self.pythonPath
        let script = self.scriptPath

        guard FileManager.default.fileExists(atPath: script) else {
            logError("WhisperBridge", "Script not found: \(script)")
            completion(false)
            return
        }

        logInfo("WhisperBridge", "Starting Python: \(python)")
        logInfo("WhisperBridge", "Script: \(script)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", script]  // -u = unbuffered stdout
        process.environment = Self.makeEnv()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] ended in
            logWarn("WhisperBridge", "Python process terminated (exit: \(ended.terminationStatus))")
            self?.handleProcessTermination(ended)
        }

        do {
            try process.run()
        } catch {
            logError("WhisperBridge", "Failed to start Python: \(error)")
            DispatchQueue.main.async { completion(false) }
            return
        }

        lock.lock()
        guard startupToken == token else {
            lock.unlock()
            process.terminate()
            DispatchQueue.main.async { completion(false) }
            return
        }
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        lock.unlock()

        // Log Python stderr for debugging
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    logDebug("Python", trimmed)
                }
            }
        }

        // 使用可逾時等待，避免 availableData 在啟動時無限阻塞。
        let readySignal = DispatchSemaphore(value: 0)
        let readyLock = NSLock()
        var startupBuffer = Data()
        var readyReceived = false
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            readyLock.lock()
            startupBuffer.append(data)
            if let text = String(data: startupBuffer, encoding: .utf8),
               text.split(separator: "\n").contains(where: { line in
                   guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
                   return json["status"] as? String == "ready"
               }) { readyReceived = true }
            let done = readyReceived || data.isEmpty
            readyLock.unlock()
            if done { readySignal.signal() }
        }
        let waited = readySignal.wait(timeout: .now() + 60)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        readyLock.lock(); let received = readyReceived; readyLock.unlock()
        lock.lock()
        let stillCurrent = startupToken == token && self.process === process
        if received && stillCurrent { self.isReady = true }
        lock.unlock()
        guard waited == .success, received, stillCurrent else {
            process.terminate()
            DispatchQueue.main.async { completion(false) }
            return
        }

        // Start async read loop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readLoop(pipe: stdoutPipe, owner: process)
        }

        // Schedule health ping
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.startupToken == token && self.process === process
            self.lock.unlock()
            guard current else { return }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }

        logInfo("WhisperBridge", "Python backend ready ✅")
        DispatchQueue.main.async {
            self.lock.lock()
            let current = self.startupToken == token && self.isReady && self.process === process
            self.lock.unlock()
            completion(current)
        }
    }

    private func handleProcessTermination(_ ended: Process) {
        lock.lock()
        guard process === ended else { lock.unlock(); return }
        isReady = false
        process = nil
        startupToken = nil
        let pending = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()

        let error = NSError(domain: "WhisperBridge", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Python process terminated unexpectedly"])
        DispatchQueue.main.async {
            self.lock.lock()
            let stopped = self.process == nil
            self.lock.unlock()
            if stopped { AppState.shared.hasPythonBackend = false }
            for (_, context) in pending {
                context.timeoutItem.cancel()
                context.completion(.failure(error))
            }
        }
    }

    func stopProcess() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
            self?.idleTimer?.invalidate()
            self?.idleTimer = nil
        }

        lock.lock()
        isReady = false
        startupToken = nil
        let proc = process
        process = nil
        let pending = pendingRequests
        pendingRequests.removeAll()
        readBuffer = ""
        stdinPipe?.fileHandleForWriting.closeFile()
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        lock.unlock()

        proc?.terminate()
        let error = NSError(domain: "WhisperBridge", code: NSUserCancelledError,
                            userInfo: [NSLocalizedDescriptionKey: "辨識已取消"])
        for context in pending.values {
            context.timeoutItem.cancel()
            DispatchQueue.main.async { context.completion(.failure(error)) }
        }
        logInfo("WhisperBridge", "Python process stopped")
    }

    // MARK: - Reading

    private func readLoop(pipe: Pipe, owner: Process) {

        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty {
                lock.lock()
                let running = process === owner && owner.isRunning
                lock.unlock()
                if !running { break }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            guard let text = String(data: data, encoding: .utf8) else { continue }

            lock.lock()
            guard process === owner else { lock.unlock(); break }
            readBuffer += text
            lock.unlock()

            processBuffer()
        }
        logWarn("WhisperBridge", "Read loop ended")
    }

    private func processBuffer() {
        lock.lock()
        var lines: [String] = []
        while let range = readBuffer.range(of: "\n") {
            let line = String(readBuffer[readBuffer.startIndex..<range.lowerBound])
            readBuffer.removeSubrange(readBuffer.startIndex...range.lowerBound)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        lock.unlock()

        for line in lines { handleResponse(line) }
    }

    private func handleResponse(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logWarn("WhisperBridge", "Invalid JSON response: \(String(line.prefix(100)))")
            return
        }

        // Ignore pong responses
        if let status = json["status"] as? String, status == "pong" { return }

        guard let id = json["id"] as? String else { return }

        lock.lock()
        let context = pendingRequests.removeValue(forKey: id)
        lock.unlock()

        guard let context = context else { return }
        context.timeoutItem.cancel()
        let elapsed = Date().timeIntervalSince(context.startTime)
        logInfo("WhisperBridge", "\(context.label) latency: \(String(format: "%.2f", elapsed))s")

        if let errorMsg = json["error"] as? String, !errorMsg.isEmpty {
            let err = NSError(domain: "WhisperBridge", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: errorMsg])
            DispatchQueue.main.async { context.completion(.failure(err)) }
        } else if let text = json["text"] as? String {
            logInfo("WhisperBridge", "Transcription (\(text.count) chars): \(text.prefix(80))")
            DispatchQueue.main.async { context.completion(.success(text)) }
        } else {
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response from Python"])
            DispatchQueue.main.async { context.completion(.failure(err)) }
        }
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL, model: String?, language: String?, modelType: String? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        guard isReady else {
            lock.unlock()
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Python backend not ready. Please complete setup first."])
            completion(.failure(err))
            return
        }
        lock.unlock()

        resetIdleTimer()

        var request: [String: Any] = [
            "action": "transcribe",
            "audio_path": audioURL.path,
            "model_type": modelType ?? AppState.shared.selectedModel.modelType
        ]
        if let model = model, !model.isEmpty { request["model"] = model }
        if let lang = language, !lang.isEmpty, lang != "auto" { request["language"] = lang }
        let prompt = DictionaryService.shared.buildPrompt(basePrompt: AppState.shared.initialPrompt)
        if !prompt.isEmpty { request["initial_prompt"] = prompt }
        if AppState.shared.removeFillers { request["remove_fillers"] = true }

        queueRequest(payload: request, timeout: requestTimeout, label: "Transcribe") { result in
            completion(result)
        }
    }

    private func queueRequest(payload: [String: Any], timeout: TimeInterval, label: String,
                              completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        guard isReady, let pipe = stdinPipe else {
            lock.unlock()
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Python backend not ready"])
            DispatchQueue.main.async { completion(.failure(err)) }
            return
        }
        let id = payload["id"] as? String ?? UUID().uuidString
        var request = payload
        request["id"] = id

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let context = self.pendingRequests.removeValue(forKey: id)
            self.lock.unlock()
            guard let context = context else { return }
            logError("WhisperBridge", "\(label) timed out after \(timeout)s")
            let err = NSError(domain: "WhisperBridge", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "\(label) timed out"])
            DispatchQueue.main.async { context.completion(.failure(err)) }
        }

        let context = RequestContext(completion: completion, startTime: Date(), timeoutItem: timeoutItem, label: label)
        pendingRequests[id] = context
        lock.unlock()

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: request)
            var line = jsonData
            line.append(contentsOf: "\n".data(using: .utf8)!)
            try pipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            lock.lock()
            let context = pendingRequests.removeValue(forKey: id)
            lock.unlock()
            if let context {
                context.timeoutItem.cancel()
                DispatchQueue.main.async { context.completion(.failure(error)) }
            }
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    // MARK: - Idle Timer

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.idleTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
                logInfo("WhisperBridge", "Idle timeout — stopping Python process to save power")
                self?.stopProcess()
                DispatchQueue.main.async {
                    AppState.shared.hasPythonBackend = false
                }
            }
        }
    }

    // MARK: - Health Ping
    private func sendPing() {
        lock.lock()
        guard isReady, let pipe = stdinPipe else {
            lock.unlock()
            return
        }
        lock.unlock()

        let request: [String: Any] = ["action": "ping", "id": UUID().uuidString]
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            var line = data
            line.append(contentsOf: "\n".data(using: .utf8)!)
            try pipe.fileHandleForWriting.write(contentsOf: line)
        } catch {}
    }

    // MARK: - Environment

    static func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let venvBin = NSHomeDirectory() + "/.local/share/typelessmlx/venv/bin"
        let paths = [venvBin, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (paths + [(env["PATH"] ?? "")]).joined(separator: ":")
        env["HF_HOME"] = NSHomeDirectory() + "/.cache/huggingface"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }
}
