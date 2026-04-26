import AppKit
import SwiftUI

class SetupWindowController: NSObject {
    static let shared = SetupWindowController()

    private var window: NSWindow?
    private var viewModel: SetupViewModel?

    func show(onComplete: (() -> Void)? = nil) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = SetupViewModel(onComplete: onComplete)
        self.viewModel = vm

        let contentView = SetupView(viewModel: vm)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 420)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TypelessMLX 設定"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        vm.checkAll()
    }

    func close() {
        window?.close()
        window = nil
        viewModel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - ViewModel

class SetupViewModel: ObservableObject {
    enum StepStatus { case unknown, running, done, failed(String) }

    @Published var venvStatus: StepStatus = .unknown
    @Published var logLines: [String] = []
    @Published var isRunning = false
    @Published var allDone = false

    private var onComplete: (() -> Void)?

    init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    func checkAll() {
        DispatchQueue.main.async {
            self.venvStatus = WhisperBridge.isVenvReady() ? .done : .unknown
            self.updateAllDone()
        }
    }

    func runSetup() {
        guard !isRunning else { return }
        isRunning = true
        logLines.removeAll()

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Create Python venv
            if !WhisperBridge.isVenvReady() {
                DispatchQueue.main.async { self.venvStatus = .running }
                self.appendLog("🔧 建立 Python 虛擬環境...")
                if self.createVenv() {
                    DispatchQueue.main.async { self.venvStatus = .done }
                    self.appendLog("✅ Python 虛擬環境建立完成")
                } else {
                    DispatchQueue.main.async { self.venvStatus = .failed("建立失敗") }
                    self.appendLog("❌ Python 虛擬環境建立失敗，請確認已安裝 uv")
                    DispatchQueue.main.async { self.isRunning = false }
                    return
                }
            } else {
                self.appendLog("✅ Python 虛擬環境已存在")
            }

            self.appendLog("")
            self.appendLog("🎉 設定完成！請按 \(AppState.shared.hotkeyDisplayName) 開始錄音。")

            DispatchQueue.main.async {
                self.isRunning = false
                self.updateAllDone()
                // Start WhisperBridge
                WhisperBridge.shared.start { success in
                    AppState.shared.hasPythonBackend = success
                    AppState.shared.updatePermissionState()
                    logInfo("Setup", "WhisperBridge start: \(success)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.onComplete?()
                    SetupWindowController.shared.close()
                }
            }
        }
    }

    private func createVenv() -> Bool {
        // First try: uv
        let venvPath = NSHomeDirectory() + "/.local/share/typelessmlx/venv"
        let requirementsPath = findRequirementsPath()

        for uvPath in ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "uv"] {
            if let uvURL = findExecutable(uvPath) {
                appendLog("   使用 uv 建立 venv: \(uvURL.path)")
                let result = runCommand(uvURL.path, args: ["venv", venvPath, "--python", "3.12"],
                                        env: WhisperBridge.makeEnv())
                if result {
                    appendLog("   安裝 Python 套件...")
                    let python = venvPath + "/bin/python"
                    let installResult = runCommand(uvURL.path,
                                                   args: ["pip", "install", "-p", python, "-r", requirementsPath ?? "requirements.txt"],
                                                   env: WhisperBridge.makeEnv())
                    return installResult
                }
            }
        }

        // Fallback: python3 -m venv
        appendLog("   uv 未找到，嘗試 python3 -m venv...")
        for pyPath in ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: pyPath) {
                let venvResult = runCommand(pyPath, args: ["-m", "venv", venvPath], env: WhisperBridge.makeEnv())
                if venvResult {
                    let pip = venvPath + "/bin/pip"
                    let req = requirementsPath ?? ""
                    if req.isEmpty { return false }
                    return runCommand(pip, args: ["install", "-r", req], env: WhisperBridge.makeEnv())
                }
            }
        }
        return false
    }

    private func findRequirementsPath() -> String? {
        if let bundlePath = Bundle.main.path(forResource: "requirements", ofType: "txt", inDirectory: "backend") {
            return bundlePath
        }
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend/requirements.txt").path
        return FileManager.default.fileExists(atPath: devPath) ? devPath : nil
    }

    private func findExecutable(_ path: String) -> URL? {
        if path.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        // Search PATH
        let env = WhisperBridge.makeEnv()
        let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in paths {
            let full = dir + "/" + path
            if FileManager.default.fileExists(atPath: full) { return URL(fileURLWithPath: full) }
        }
        return nil
    }

    private func runCommand(_ executable: String, args: [String], env: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for line in lines { self?.appendLog("   \(line)") }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for line in lines { self?.appendLog("   \(line)") }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return process.terminationStatus == 0
        } catch {
            appendLog("   執行失敗: \(error)")
            return false
        }
    }

    private func updateAllDone() {
        if case .done = venvStatus {
            allDone = true
        } else {
            allDone = false
        }
    }

    func appendLog(_ line: String) {
        if Thread.isMainThread {
            logLines.append(line)
        } else {
            DispatchQueue.main.async { self.logLines.append(line) }
        }
    }
}

// MARK: - SwiftUI View

struct SetupView: View {
    @ObservedObject var viewModel: SetupViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TypelessMLX 設定")
                        .font(.title2.bold())
                    Text("設定 Python 環境（語音模型將在首次選用時自動下載）")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)

            // Steps
            VStack(spacing: 8) {
                stepRow(icon: "python.circle.fill",
                        title: "Python 虛擬環境",
                        subtitle: "安裝 mlx-whisper 及相依套件",
                        status: viewModel.venvStatus)
            }
            .padding(.horizontal)

            // Log
            VStack(alignment: .leading, spacing: 4) {
                Text("安裝日誌")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(logColor(for: line))
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    .onChange(of: viewModel.logLines.count) { _ in
                        if let last = viewModel.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Buttons
            HStack {
                Button("重新檢查") { viewModel.checkAll() }
                    .disabled(viewModel.isRunning)

                Spacer()

                if viewModel.isRunning {
                    ProgressView().controlSize(.small).padding(.trailing, 8)
                }

                Button("開始安裝") { viewModel.runSetup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRunning)

                Button("關閉") { SetupWindowController.shared.close() }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func stepRow(icon: String, title: String, subtitle: String, status: SetupViewModel.StepStatus) -> some View {
        HStack(spacing: 12) {
            statusIcon(status: status).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.bold())
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            statusLabel(status: status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private func statusIcon(status: SetupViewModel.StepStatus) -> some View {
        switch status {
        case .unknown: Image(systemName: "circle.dashed").foregroundColor(.gray)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private func statusLabel(status: SetupViewModel.StepStatus) -> some View {
        switch status {
        case .unknown: Text("未檢查").font(.caption).foregroundColor(.gray)
        case .running: Text("進行中...").font(.caption).foregroundColor(.orange)
        case .done: Text("完成").font(.caption).foregroundColor(.green)
        case .failed(let msg): Text("失敗").font(.caption).foregroundColor(.red).help(msg)
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("✅") || line.contains("🎉") { return .green }
        if line.contains("❌") { return .red }
        if line.contains("⚠️") || line.contains("失敗") { return .orange }
        if line.contains("🔧") || line.contains("🔄") { return .blue }
        return .primary
    }
}
