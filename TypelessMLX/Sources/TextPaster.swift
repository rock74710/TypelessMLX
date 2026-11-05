import Cocoa
import Carbon
import TypelessMLXWorkflowSupport

/// 未取得完整欄位與選取資訊時，保守改用文字救援。
struct PasteTarget {
    let pid: pid_t
    let window: AXUIElement
    let field: AXUIElement
    let selection: CFRange
}

class TextPaster {
    static let shared = TextPaster()
    private lazy var transaction = PasteTransaction(
        pasteboard: .general,
        schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        send: { Self.postPasteEvent() }
    )
    private init() {}
    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func focusedField() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let field = attribute(element, kAXFocusedUIElementAttribute),
              CFGetTypeID(field) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(field, to: AXUIElement.self)
    }
    static var secureInputActive: Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let field = focusedField() else { return false }
        return (attribute(field, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }
    static func captureTarget() -> PasteTarget? {
        guard isAccessibilityGranted, !secureInputActive,
              let app = NSWorkspace.shared.frontmostApplication,
              let field = focusedField(),
              let role = attribute(field, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              let rawWindow = attribute(field, kAXWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID(),
              let selection = attribute(field, kAXSelectedTextRangeAttribute),
              CFGetTypeID(selection) == AXValueGetTypeID(),
              AXValueGetType(unsafeBitCast(selection, to: AXValue.self)) == .cfRange else { return nil }
        var valueSettable = DarwinBoolean(false)
        var selectedTextSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &valueSettable)
        _ = AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
        guard valueSettable.boolValue || selectedTextSettable.boolValue else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(selection, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return PasteTarget(pid: app.processIdentifier, window: unsafeBitCast(rawWindow, to: AXUIElement.self),
                           field: field, selection: range)
    }
    static func eligibility(for target: PasteTarget?) -> PasteEligibility {
        if secureInputActive { return .secure }
        guard isAccessibilityGranted else { return .missingPermission }
        guard let target, let now = captureTarget(), now.pid == target.pid,
              CFEqual(now.window, target.window), CFEqual(now.field, target.field),
              now.selection.location == target.selection.location, now.selection.length == target.selection.length else { return .targetChanged }
        return .allowed
    }
    func pasteText(_ text: String, target: PasteTarget?, isCurrent: @escaping () -> Bool,
                   completion: @escaping (DeliveryResult) -> Void) {
        transaction.enqueue(text, eligibility: { Self.eligibility(for: target) }, isCurrent: isCurrent) { result in
            logInfo("TextPaster", "Delivery: \(result.rawValue), chars=\(text.count)")
            completion(result)
        }
    }
    /// 手動複製仍檢查安全欄位。不自動重試貼上。
    @discardableResult func copyText(_ text: String) -> Bool {
        guard !Self.secureInputActive else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
    private static func postPasteEvent() -> Bool {
        guard isAccessibilityGranted, !secureInputActive,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
}
