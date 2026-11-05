import SwiftUI
import AVFoundation

@main
struct TypelessMLXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    let appState = AppState.shared
    private var permissionCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashHandler()
        logInfo("App", "TypelessMLX launching...")

        // Menu bar only app — no Dock icon
        NSApp.setActivationPolicy(.accessory)

        // Setup status bar
        statusBarController = StatusBarController(appState: appState)

        // Check permissions
        checkPermissions()

        // Request speech recognition authorization (for live preview + macOS built-in model)
        SpeechStreamer.requestAuthorization { granted in
            logInfo("App", "Speech recognition authorization: \(granted)")
        }

        // Check if Python venv is ready; if not, show setup
        checkBackendAndSetup()

        // Pre-warm Apple Foundation Models session if enabled
        warmUpTextRefinerIfNeeded()

        // Setup hotkey (works even before permissions are fully granted)
        HotkeyManager.shared.setup(appState: appState)

        // Periodically re-check permissions
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.recheckPermissions()
        }

        logInfo("App", "TypelessMLX launch complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionCheckTimer?.invalidate()
        logInfo("App", "TypelessMLX shutting down")
        HotkeyManager.shared.cancelCurrentTask()
        ModelManager.shared.cancelDownload()
        AudioRecorder.shared.forceReset()
        WhisperBridge.shared.stopProcess()
    }

    private func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let msg = "UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "unknown")"
            logError("CRASH", msg)
            Thread.sleep(forTimeInterval: 0.5)
        }
        logInfo("App", "Crash handler installed")
    }

    private func checkPermissions() {
        logInfo("App", "Checking permissions...")

        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.appState.hasMicPermission = granted
                    self.appState.updatePermissionState()
                    if !granted {
                        self.appState.showError("麥克風存取被拒絕。請前往系統設定 → 隱私權 → 麥克風 啟用。")
                    }
                }
            }
        case .denied, .restricted:
            appState.hasMicPermission = false
            appState.showError("麥克風存取被拒絕。請前往系統設定 → 隱私權 → 麥克風 啟用。")
        case .authorized:
            appState.hasMicPermission = true
        @unknown default:
            break
        }

        // Accessibility
        let axTrusted = AXIsProcessTrusted()
        appState.hasAccessibilityPermission = axTrusted
        if !axTrusted {
            showAccessibilityAlert()
        }

        appState.updatePermissionState()
    }

    private func recheckPermissions() {
        let ax = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        DispatchQueue.main.async {
            let changed = (self.appState.hasAccessibilityPermission != ax) ||
                          (self.appState.hasMicPermission != mic)
            self.appState.hasAccessibilityPermission = ax
            self.appState.hasMicPermission = mic
            if changed { self.appState.updatePermissionState() }
        }
    }

    private func warmUpTextRefinerIfNeeded() {
        if #available(macOS 26, *) {
            if appState.enableTextRefinement {
                Task { await TextRefiner.shared.warmUp() }
            }
        }
    }

    private func checkBackendAndSetup() {
        if WhisperBridge.isVenvReady() {
            logInfo("App", "Python venv ready — starting WhisperBridge")
            WhisperBridge.shared.start { [weak self] success in
                self?.appState.hasPythonBackend = WhisperBridge.shared.backendIsReady
                self?.appState.updatePermissionState()
                logInfo("App", "WhisperBridge started: \(success)")
            }
        } else {
            logInfo("App", "Python venv not ready — showing setup")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SetupWindowController.shared.show {
                    logInfo("App", "Setup complete")
                }
            }
        }
    }

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要輔助使用權限"
            alert.informativeText = """
            TypelessMLX 需要輔助使用權限，才能將辨識文字貼入其他應用程式。

            請點擊「開啟設定」：
            1. 點擊 + 按鈕
            2. 選擇 TypelessMLX.app 並加入
            3. 開啟開關

            授權後可能需要重新啟動 TypelessMLX。
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "開啟設定")
            alert.addButton(withTitle: "稍後再說")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                TextPaster.openAccessibilitySettings()
            }
        }
    }
}
