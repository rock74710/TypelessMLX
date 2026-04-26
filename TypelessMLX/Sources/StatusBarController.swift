import AppKit
import SwiftUI
import Combine
import UserNotifications

class StatusBarController {
    private var statusItem: NSStatusItem
    private var appState: AppState
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupButton()
        setupMenu()
        observeState()
    }

    private func setupButton() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "TypelessMLX")
            button.image?.isTemplate = true
        }
    }

    private func setupMenu() {
        updateMenu()
    }

    private func observeState() {
        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateIcon(for: status)
                self?.updateMenu()
            }
            .store(in: &cancellables)

        appState.$permissionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenu() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenu() }
            .store(in: &cancellables)

        appState.$errorMessage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.showNotification(title: "TypelessMLX", body: message)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for status: AppStatus) {
        guard let button = statusItem.button else { return }
        switch status {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "TypelessMLX - 待機")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "TypelessMLX - 錄音中")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        case .transcribing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "TypelessMLX - 辨識中")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        }
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Permission/status indicator
        let permItem = NSMenuItem(title: appState.permissionState.rawValue, action: nil, keyEquivalent: "")
        permItem.isEnabled = false
        menu.addItem(permItem)

        if appState.permissionState != .ready {
            if !appState.hasMicPermission {
                let item = NSMenuItem(title: "  ⚠️ 麥克風：未授權", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if !appState.hasAccessibilityPermission {
                let item = NSMenuItem(title: "  ⚠️ 輔助使用：未授權", action: #selector(openAccessibilitySettings), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            if !appState.hasPythonBackend {
                let item = NSMenuItem(title: "  ⚠️ Python 後端：未就緒", action: #selector(showSetup), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Current model
        let modelItem = NSMenuItem(title: "模型：\(appState.selectedModel.id)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        // Status
        let statusItem = NSMenuItem(title: appState.status.rawValue, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        // Hotkey hint
        let modeText = appState.hotkeyMode == "hold" ? "按住錄音" : "按一下切換錄音"
        let hintItem = NSMenuItem(title: "\(appState.hotkeyDisplayName) → \(modeText)", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        // Last transcription
        if let lastEntry = appState.history.first {
            menu.addItem(NSMenuItem.separator())
            let preview = String(lastEntry.text.prefix(50)) + (lastEntry.text.count > 50 ? "…" : "")
            let lastItem = NSMenuItem(title: "最近：\(preview)", action: #selector(copyLastTranscription), keyEquivalent: "")
            lastItem.target = self
            lastItem.toolTip = lastEntry.text
            menu.addItem(lastItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Setup / Settings
        let setupItem = NSMenuItem(title: "設定與安裝...", action: #selector(showSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let settingsItem = NSMenuItem(title: "偏好設定...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let refreshItem = NSMenuItem(title: "重新整理權限", action: #selector(refreshPermissions), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "結束 TypelessMLX", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    @objc private func openAccessibilitySettings() {
        TextPaster.openAccessibilitySettings()
    }

    @objc private func showSetup() {
        SetupWindowController.shared.show()
    }

    @objc private func copyLastTranscription() {
        guard let last = appState.history.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.text, forType: .string)
        showNotification(title: "已複製", body: String(last.text.prefix(50)))
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(appState: appState)
    }

    @objc private func refreshPermissions() {
        appState.refreshPermissions()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(appState: AppState) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 380)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TypelessMLX 偏好設定"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
