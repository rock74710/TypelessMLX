import Foundation

public final class RecoveryStore {
    private let directory: URL
    private let maxAge: TimeInterval
    private let maxCount: Int
    private let maxBytes: Int
    private let fm = FileManager.default
    public init(directory: URL, maxAge: TimeInterval = 86400, maxCount: Int = 10,
                maxBytes: Int = 200 * 1024 * 1024, now: Date = Date()) throws {
        self.directory = directory; self.maxAge = maxAge; self.maxCount = maxCount; self.maxBytes = maxBytes
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try cleanup(now: now)
    }
    public var identifiers: [String] { files().map { $0.lastPathComponent } }
    public func url(for identifier: String) -> URL? {
        guard identifier.hasSuffix(".wav"), UUID(uuidString: String(identifier.dropLast(4))) != nil else { return nil }
        let url = directory.appendingPathComponent(identifier)
        guard let a = try? fm.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeRegular else { return nil }
        return url
    }
    @discardableResult public func retain(_ source: URL, now: Date = Date()) throws -> String {
        let size = (try fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let id = UUID().uuidString + ".wav"
        let target = directory.appendingPathComponent(id)
        do {
            try fm.copyItem(at: source, to: target)
            try fm.setAttributes([.posixPermissions: 0o600, .modificationDate: now], ofItemAtPath: target.path)
            try cleanup(now: now)
            try fm.removeItem(at: source)
            return id
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }
    public func remove(_ identifier: String) {
        guard let url = url(for: identifier) else { return }
        try? fm.removeItem(at: url)
    }
    public func clear() throws { for url in files() { try fm.removeItem(at: url) } }
    public func cleanup(now: Date = Date()) throws {
        var kept: [(URL, Date, Int)] = []
        for url in files() {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let date = attrs[.modificationDate] as? Date ?? .distantPast
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if now.timeIntervalSince(date) >= maxAge { try fm.removeItem(at: url) }
            else { kept.append((url, date, size)) }
        }
        kept.sort { $0.1 > $1.1 }
        var bytes = 0
        for (index, item) in kept.enumerated() {
            bytes += item.2
            if index >= maxCount || bytes > maxBytes { try fm.removeItem(at: item.0) }
        }
    }
    private func files() -> [URL] {
        ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { url(for: $0.lastPathComponent) != nil }
    }
}
