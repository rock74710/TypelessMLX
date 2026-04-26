import AppKit
import Carbon

struct RecognitionHotkey: Identifiable, Equatable {
    private enum DeviceMask {
        static let leftControl: UInt64 = 0x00000001
        static let leftShift: UInt64 = 0x00000002
        static let rightShift: UInt64 = 0x00000004
        static let leftCommand: UInt64 = 0x00000008
        static let rightCommand: UInt64 = 0x00000010
        static let leftOption: UInt64 = 0x00000020
        static let rightOption: UInt64 = 0x00000040
        static let rightControl: UInt64 = 0x00002000
    }

    enum ModifierKind {
        case option
        case control
        case command
        case shift

        func isActive(_ flags: NSEvent.ModifierFlags) -> Bool {
            switch self {
            case .option:
                return flags.contains(.option)
            case .control:
                return flags.contains(.control)
            case .command:
                return flags.contains(.command)
            case .shift:
                return flags.contains(.shift)
            }
        }

        func isActive(_ flags: CGEventFlags) -> Bool {
            switch self {
            case .option:
                return flags.contains(.maskAlternate)
            case .control:
                return flags.contains(.maskControl)
            case .command:
                return flags.contains(.maskCommand)
            case .shift:
                return flags.contains(.maskShift)
            }
        }
    }

    let keyCode: Int
    let displayName: String
    let modifier: ModifierKind
    let relatedKeyCodes: Set<Int>
    let deviceMask: UInt64?

    var id: Int { keyCode }

    static let defaultKeyCode = kVK_RightOption

    static let all: [RecognitionHotkey] = [
        RecognitionHotkey(
            keyCode: kVK_RightOption,
            displayName: "Right Option",
            modifier: .option,
            relatedKeyCodes: [kVK_Option, kVK_RightOption],
            deviceMask: DeviceMask.rightOption
        ),
        RecognitionHotkey(
            keyCode: kVK_Option,
            displayName: "Left Option",
            modifier: .option,
            relatedKeyCodes: [kVK_Option, kVK_RightOption],
            deviceMask: DeviceMask.leftOption
        ),
        RecognitionHotkey(
            keyCode: kVK_RightControl,
            displayName: "Right Control",
            modifier: .control,
            relatedKeyCodes: [kVK_Control, kVK_RightControl],
            deviceMask: DeviceMask.rightControl
        ),
        RecognitionHotkey(
            keyCode: kVK_Control,
            displayName: "Left Control",
            modifier: .control,
            relatedKeyCodes: [kVK_Control, kVK_RightControl],
            deviceMask: DeviceMask.leftControl
        ),
        RecognitionHotkey(
            keyCode: kVK_RightCommand,
            displayName: "Right Command",
            modifier: .command,
            relatedKeyCodes: [kVK_Command, kVK_RightCommand],
            deviceMask: DeviceMask.rightCommand
        ),
        RecognitionHotkey(
            keyCode: kVK_Command,
            displayName: "Left Command",
            modifier: .command,
            relatedKeyCodes: [kVK_Command, kVK_RightCommand],
            deviceMask: DeviceMask.leftCommand
        ),
        RecognitionHotkey(
            keyCode: kVK_RightShift,
            displayName: "Right Shift",
            modifier: .shift,
            relatedKeyCodes: [kVK_Shift, kVK_RightShift],
            deviceMask: DeviceMask.rightShift
        ),
        RecognitionHotkey(
            keyCode: kVK_Shift,
            displayName: "Left Shift",
            modifier: .shift,
            relatedKeyCodes: [kVK_Shift, kVK_RightShift],
            deviceMask: DeviceMask.leftShift
        )
    ]

    static func resolve(keyCode: Int) -> RecognitionHotkey {
        all.first { $0.keyCode == keyCode } ?? all[0]
    }

    func isRelevant(eventKeyCode: Int, flagsRaw: UInt64, wasHotkeyDown: Bool) -> Bool {
        if eventKeyCode == keyCode {
            return true
        }
        if isDeviceMaskActive(flagsRaw) {
            return true
        }
        return wasHotkeyDown && relatedKeyCodes.contains(eventKeyCode)
    }

    func isPressed(eventKeyCode: Int, flagsRaw: UInt64, modifierIsActive: Bool) -> Bool {
        if isDeviceMaskActive(flagsRaw) {
            return true
        }
        if eventKeyCode == keyCode {
            return modifierIsActive
        }
        return false
    }

    private func isDeviceMaskActive(_ flagsRaw: UInt64) -> Bool {
        guard let deviceMask else { return false }
        return flagsRaw & deviceMask != 0
    }
}
