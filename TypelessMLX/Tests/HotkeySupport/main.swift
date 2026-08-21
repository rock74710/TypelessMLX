import Foundation
import TypelessMLXHotkeySupport

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func testSupportedMappings() {
    let expected: [(Int, HotkeyModifier, HotkeySide, String)] = [
        (58, .option, .left, "Left ⌥ Option"),
        (61, .option, .right, "Right ⌥ Option"),
        (55, .command, .left, "Left ⌘ Command"),
        (54, .command, .right, "Right ⌘ Command"),
        (59, .control, .left, "Left ⌃ Control"),
        (62, .control, .right, "Right ⌃ Control"),
        (56, .shift, .left, "Left ⇧ Shift"),
        (60, .shift, .right, "Right ⇧ Shift")
    ]

    expect(
        HotkeyDefinition.supportedDefinitions.count == expected.count,
        "all eight single-modifier mappings should be present"
    )

    for (keyCode, modifier, side, displayName) in expected {
        guard let definition = HotkeyDefinition.definition(forKeyCode: keyCode) else {
            fatalError("missing supported key code \(keyCode)")
        }
        expect(definition.modifier == modifier, "wrong modifier for key code \(keyCode)")
        expect(definition.side == side, "wrong side for key code \(keyCode)")
        expect(definition.displayName == displayName, "wrong display name for key code \(keyCode)")
        expect(HotkeyDefinition.isSupportedKeyCode(keyCode), "key code \(keyCode) should be supported")
    }
}

func testInvalidValuesFallBackToRightOption() {
    for invalidKeyCode in [-1, 0, 1, 57, 63, 1000] {
        expect(
            HotkeyDefinition.definition(forKeyCode: invalidKeyCode) == nil,
            "key code \(invalidKeyCode) should not be supported"
        )
        expect(
            HotkeyDefinition.sanitizedKeyCode(invalidKeyCode) == HotkeyDefinition.defaultDefinition.keyCode,
            "invalid key code \(invalidKeyCode) should fall back to Right Option"
        )
        expect(
            HotkeyDefinition.sanitizedDefinition(forKeyCode: invalidKeyCode) == HotkeyDefinition.defaultDefinition,
            "invalid key code \(invalidKeyCode) should use the default definition"
        )
    }
}

func state(for modifier: HotkeyModifier, isDown: Bool) -> HotkeyModifierState {
    switch modifier {
    case .option: return HotkeyModifierState(option: isDown)
    case .command: return HotkeyModifierState(command: isDown)
    case .control: return HotkeyModifierState(control: isDown)
    case .shift: return HotkeyModifierState(shift: isDown)
    }
}

func testKeyDownAndKeyUpTransitions() {
    for definition in HotkeyDefinition.supportedDefinitions {
        let down = state(for: definition.modifier, isDown: true)
        let up = state(for: definition.modifier, isDown: false)

        expect(definition.isKeyDown(for: down), "key-down should be true for \(definition.displayName)")
        expect(!definition.isKeyDown(for: up), "key-up should be false for \(definition.displayName)")
        expect(definition.transition(for: down) == .keyDown, "wrong key-down transition")
        expect(definition.transition(for: up) == .keyUp, "wrong key-up transition")
        expect(
            definition.matches(keyCode: definition.keyCode, state: down),
            "matching key code and key-down state should match"
        )
        expect(
            !definition.matches(keyCode: definition.keyCode + 1, state: down),
            "a different key code should not match"
        )
    }
}

func testModifierFlagRawValueMapping() {
    let state = HotkeyModifierState(
        eventModifierFlagsRawValue:
            HotkeyModifierState.optionFlagRawValue
            | HotkeyModifierState.commandFlagRawValue
            | HotkeyModifierState.controlFlagRawValue
            | HotkeyModifierState.shiftFlagRawValue
    )
    expect(state.option, "Option raw flag should map to option")
    expect(state.command, "Command raw flag should map to command")
    expect(state.control, "Control raw flag should map to control")
    expect(state.shift, "Shift raw flag should map to shift")

    let empty = HotkeyModifierState(eventModifierFlagsRawValue: 0)
    expect(!empty.option && !empty.command && !empty.control && !empty.shift, "empty flags should be unpressed")
}

testSupportedMappings()
testInvalidValuesFallBackToRightOption()
testKeyDownAndKeyUpTransitions()
testModifierFlagRawValueMapping()
print("TypelessMLXHotkeySupportTests passed")
