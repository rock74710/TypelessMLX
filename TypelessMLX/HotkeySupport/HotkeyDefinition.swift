import Foundation

/// The four modifier families that can be used as a dictation hotkey.
///
/// This type deliberately does not depend on AppKit.  NSEvent flags are
/// converted to `HotkeyModifierState` at the app boundary so the mapping and
/// transition logic can be exercised by a small offline executable test.
public enum HotkeyModifier: String, CaseIterable, Sendable {
    case option
    case command
    case control
    case shift

    public var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    public var displayName: String {
        switch self {
        case .option: return "Option"
        case .command: return "Command"
        case .control: return "Control"
        case .shift: return "Shift"
        }
    }
}

/// Which side of the keyboard the modifier belongs to.
public enum HotkeySide: String, CaseIterable, Sendable {
    case left
    case right

    public var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// The modifier state needed by the hotkey state machine.
///
/// It is intentionally a value type with explicit booleans rather than an
/// AppKit `NSEvent.ModifierFlags` wrapper.  This keeps all key-code and
/// key-down/key-up rules platform-neutral and easy to test.
public struct HotkeyModifierState: Equatable, Sendable {
    // NSEvent.ModifierFlags uses these device-independent bit positions. Keep
    // the platform raw-value knowledge here so event consumers do not each
    // maintain their own modifier-to-flag mapping.
    public static let shiftFlagRawValue: UInt = 1 << 17
    public static let controlFlagRawValue: UInt = 1 << 18
    public static let optionFlagRawValue: UInt = 1 << 19
    public static let commandFlagRawValue: UInt = 1 << 20

    public let option: Bool
    public let command: Bool
    public let control: Bool
    public let shift: Bool

    public init(
        option: Bool = false,
        command: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) {
        self.option = option
        self.command = command
        self.control = control
        self.shift = shift
    }

    public init(eventModifierFlagsRawValue rawValue: UInt) {
        self.init(
            option: rawValue & Self.optionFlagRawValue != 0,
            command: rawValue & Self.commandFlagRawValue != 0,
            control: rawValue & Self.controlFlagRawValue != 0,
            shift: rawValue & Self.shiftFlagRawValue != 0
        )
    }

    public func contains(_ modifier: HotkeyModifier) -> Bool {
        switch modifier {
        case .option: return option
        case .command: return command
        case .control: return control
        case .shift: return shift
        }
    }
}

public enum HotkeyTransition: Equatable, Sendable {
    case keyDown
    case keyUp
}

/// A supported single-modifier dictation hotkey.
public struct HotkeyDefinition: Equatable, Sendable {
    public let keyCode: Int
    public let modifier: HotkeyModifier
    public let side: HotkeySide

    public init(keyCode: Int, modifier: HotkeyModifier, side: HotkeySide) {
        self.keyCode = keyCode
        self.modifier = modifier
        self.side = side
    }

    public var displayName: String {
        "\(side.displayName) \(modifier.symbol) \(modifier.displayName)"
    }

    /// Existing installations use Right Option (virtual key code 61).
    public static let defaultDefinition = HotkeyDefinition(
        keyCode: 61,
        modifier: .option,
        side: .right
    )

    public static let escapeKeyCode = 53
    public static let capsLockKeyCode = 57

    /// Supported macOS virtual key-code mappings.  The list is kept in one
    /// place so the settings UI and event monitor cannot drift apart.
    public static let supportedDefinitions: [HotkeyDefinition] = [
        HotkeyDefinition(keyCode: 58, modifier: .option, side: .left),
        HotkeyDefinition(keyCode: 61, modifier: .option, side: .right),
        HotkeyDefinition(keyCode: 55, modifier: .command, side: .left),
        HotkeyDefinition(keyCode: 54, modifier: .command, side: .right),
        HotkeyDefinition(keyCode: 59, modifier: .control, side: .left),
        HotkeyDefinition(keyCode: 62, modifier: .control, side: .right),
        HotkeyDefinition(keyCode: 56, modifier: .shift, side: .left),
        HotkeyDefinition(keyCode: 60, modifier: .shift, side: .right)
    ]

    public static func definition(forKeyCode keyCode: Int) -> HotkeyDefinition? {
        supportedDefinitions.first { $0.keyCode == keyCode }
    }

    /// Returns a valid definition for persisted or user-provided input.
    /// Invalid values always fall back to the historical Right Option default.
    public static func sanitizedDefinition(forKeyCode keyCode: Int) -> HotkeyDefinition {
        definition(forKeyCode: keyCode) ?? defaultDefinition
    }

    public static func sanitizedKeyCode(_ keyCode: Int) -> Int {
        sanitizedDefinition(forKeyCode: keyCode).keyCode
    }

    public static func isSupportedKeyCode(_ keyCode: Int) -> Bool {
        definition(forKeyCode: keyCode) != nil
    }

    public static func unsupportedKeyMessage(forKeyCode keyCode: Int) -> String {
        if keyCode == capsLockKeyCode {
            return "不支援 Caps Lock，請選擇 Option、Command、Control 或 Shift"
        }
        return "不支援此按鍵，請選擇 Option、Command、Control 或 Shift"
    }

    /// Whether a flagsChanged event represents the selected modifier being
    /// pressed.  The caller must already have matched the event key code.
    public func isKeyDown(for state: HotkeyModifierState) -> Bool {
        state.contains(modifier)
    }

    public func transition(for state: HotkeyModifierState) -> HotkeyTransition {
        isKeyDown(for: state) ? .keyDown : .keyUp
    }

    public func matches(keyCode: Int, state: HotkeyModifierState) -> Bool {
        keyCode == self.keyCode && isKeyDown(for: state)
    }
}
