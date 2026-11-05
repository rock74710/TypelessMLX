/// Actions for a hold-to-talk hotkey while audio setup runs asynchronously.
public enum HoldHotkeyAction: Equatable, Sendable {
    case startPreparation
    case beginRecording
    case stopRecording
    case cancelPreparation
    case ignore
}

/// Tracks one hold-to-talk press across asynchronous recording preparation.
public struct HoldHotkeyState: Sendable {
    private enum Phase: Sendable {
        case idle
        case preparing
        case recording
    }

    private var phase: Phase = .idle

    public init() {}

    public mutating func startPreparation() -> HoldHotkeyAction {
        guard case .idle = phase else { return .ignore }
        phase = .preparing
        return .startPreparation
    }

    public mutating func preparationCompleted() -> HoldHotkeyAction {
        guard case .preparing = phase else { return .ignore }
        phase = .recording
        return .beginRecording
    }

    public mutating func release() -> HoldHotkeyAction {
        switch phase {
        case .idle:
            return .ignore
        case .preparing:
            phase = .idle
            return .cancelPreparation
        case .recording:
            phase = .idle
            return .stopRecording
        }
    }

    public mutating func reset() {
        phase = .idle
    }
}
