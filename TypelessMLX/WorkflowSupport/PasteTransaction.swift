import Cocoa

public enum PasteEligibility { case allowed, targetChanged, secure, missingPermission }

/// 在主執行緒序列化，包含還原等待期間。測試使用獨立剪貼簿與注入排程。
public final class PasteTransaction {
    public typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    private struct Job {
        let text: String
        let eligibility: () -> PasteEligibility
        let isCurrent: () -> Bool
        let completion: (DeliveryResult) -> Void
    }
    private let board: NSPasteboard
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let send: () -> Bool
    private let ownerType = NSPasteboard.PasteboardType("com.typelessmlx.paste-owner")
    private var jobs: [Job] = []
    private var active = false

    public init(pasteboard: NSPasteboard, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                send: @escaping () -> Bool) {
        board = pasteboard; self.schedule = schedule; self.send = send
    }
    public func enqueue(_ text: String, eligibility: @escaping () -> PasteEligibility,
                        isCurrent: @escaping () -> Bool, completion: @escaping (DeliveryResult) -> Void) {
        jobs.append(Job(text: text, eligibility: eligibility, isCurrent: isCurrent, completion: completion))
        startNext()
    }
    private func blockedResult(_ job: Job) -> DeliveryResult? {
        guard job.isCurrent() else { return .cancelled }
        switch job.eligibility() {
        case .allowed: return nil
        case .secure: return .blocked
        case .targetChanged: return .retained
        case .missingPermission: return .failed
        }
    }
    private func startNext() {
        guard !active, !jobs.isEmpty else { return }
        active = true
        let job = jobs.removeFirst()
        if let result = blockedResult(job) {
            job.completion(result); endJob(); return
        }
        let originalVersion = board.changeCount
        let snapshot: Snapshot = board.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        guard board.changeCount == originalVersion else { job.completion(.retained); endJob(); return }
        let owner = UUID().uuidString
        let item = NSPasteboardItem()
        item.setString(job.text, forType: .string)
        item.setString(owner, forType: ownerType)
        let clearedVersion = board.clearContents()
        guard board.writeObjects([item]) else {
            if board.changeCount == clearedVersion { writeSnapshot(snapshot) }
            job.completion(.failed); endJob(); return
        }
        let version = board.changeCount
        schedule(0.2) { [self] in
            if let result = blockedResult(job) {
                restore(snapshot, version: version, owner: owner)
                job.completion(result); endJob(); return
            }
            guard owns(version: version, owner: owner) else {
                job.completion(.retained); endJob(); return
            }
            guard send() else {
                restore(snapshot, version: version, owner: owner)
                job.completion(.failed); endJob(); return
            }
            // 事件已送出。不宣稱目標接收，不自動重試。
            job.completion(.sent)
            schedule(2) { [self] in
                restore(snapshot, version: version, owner: owner)
                endJob()
            }
        }
    }
    private func owns(version: Int, owner: String) -> Bool {
        board.changeCount == version && board.string(forType: ownerType) == owner
    }
    private func restore(_ snapshot: Snapshot, version: Int, owner: String) {
        guard owns(version: version, owner: owner) else { return }
        writeSnapshot(snapshot)
    }
    private func writeSnapshot(_ snapshot: Snapshot) {
        board.clearContents()
        let items = snapshot.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
    private func endJob() { active = false; startNext() }
}
