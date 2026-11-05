import Foundation

public enum DictationPhase: String, Codable {
    case recording, recognizing, refining, awaitingInput, completed, failed, cancelled
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

/// 僅在主執行緒操作。每個回呼必須攜帶建立時的識別碼。
public final class DictationLifecycle {
    public private(set) var id: UUID?
    public private(set) var phase: DictationPhase = .completed
    public init() {}
    @discardableResult public func begin() -> UUID {
        let token = UUID()
        id = token
        phase = .recording
        return token
    }
    public func isCurrent(_ token: UUID) -> Bool { id == token && !phase.isTerminal }
    @discardableResult public func transition(_ token: UUID, to next: DictationPhase) -> Bool {
        guard isCurrent(token), !next.isTerminal else { return false }
        phase = next
        return true
    }
    @discardableResult public func finish(_ token: UUID, phase terminal: DictationPhase) -> Bool {
        guard isCurrent(token), terminal.isTerminal else { return false }
        phase = terminal
        return true
    }
}

public enum DeliveryResult: String, Codable {
    case sent, copied, retained, cancelled, failed, blocked
    public var description: String {
        switch self {
        case .sent: return "已送出貼上事件"
        case .copied: return "僅複製"
        case .retained: return "等待手動複製"
        case .cancelled: return "已取消"
        case .failed: return "輸入失敗"
        case .blocked: return "安全輸入：未貼上或複製"
        }
    }
}

public struct TranscriptionRecord: Identifiable, Codable {
    public let id: UUID
    public var text: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let model: String
    public var originalText: String
    public var substitutedText: String?
    public var refinedText: String?
    public var delivery: DeliveryResult
    public var failureReason: String?
    public var recoveryID: String?
    public var phase: DictationPhase
    public var gainDB: Double?
    public var gainChanges: [Double]?
    public var schemaVersion: Int

    public init(id: UUID = UUID(), text: String, duration: TimeInterval, model: String,
                originalText: String? = nil, substitutedText: String? = nil, refinedText: String? = nil,
                delivery: DeliveryResult = .retained, failureReason: String? = nil,
                recoveryID: String? = nil, phase: DictationPhase = .awaitingInput, gainDB: Double? = nil,
                gainChanges: [Double]? = nil) {
        self.id = id; self.text = text; self.timestamp = Date(); self.duration = duration; self.model = model
        self.originalText = originalText ?? text; self.substitutedText = substitutedText; self.refinedText = refinedText
        self.delivery = delivery; self.failureReason = failureReason; self.recoveryID = recoveryID
        self.phase = phase; self.gainDB = gainDB; self.gainChanges = gainChanges; self.schemaVersion = 2
    }
    private enum CodingKeys: String, CodingKey {
        case id, text, timestamp, duration, model, originalText, substitutedText, refinedText, delivery
        case failureReason, recoveryID, phase, gainDB, gainChanges, schemaVersion
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        model = try c.decode(String.self, forKey: .model)
        originalText = try c.decodeIfPresent(String.self, forKey: .originalText) ?? text
        substitutedText = try c.decodeIfPresent(String.self, forKey: .substitutedText)
        refinedText = try c.decodeIfPresent(String.self, forKey: .refinedText)
        delivery = try c.decodeIfPresent(DeliveryResult.self, forKey: .delivery) ?? .retained
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        recoveryID = try c.decodeIfPresent(String.self, forKey: .recoveryID)
        phase = try c.decodeIfPresent(DictationPhase.self, forKey: .phase) ?? .completed
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB)
        gainChanges = try c.decodeIfPresent([Double].self, forKey: .gainChanges)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}
