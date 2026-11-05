import Foundation

/// Races one async operation against a timeout without waiting for cancelled work.
public enum AsyncTimeout {
    public static func run<Value: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let race = AsyncOperationRace<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.installContinuation(continuation)

                let work = Task {
                    do {
                        race.resolve(try await operation())
                    } catch {
                        race.resolve(nil)
                    }
                }
                race.installWorkTask(work)

                let timeout = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    race.resolve(nil)
                }
                race.installTimeoutTask(timeout)
            }
        } onCancel: {
            race.resolve(nil)
        }
    }
}

private final class AsyncOperationRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var workTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    func installContinuation(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        let shouldResume = isResolved
        if !shouldResume { self.continuation = continuation }
        lock.unlock()
        if shouldResume { continuation.resume(returning: nil) }
    }

    func installWorkTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = isResolved
        if !shouldCancel { workTask = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = isResolved
        if !shouldCancel { timeoutTask = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func resolve(_ value: Value?) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        let hasNoValue: Bool
        if case .none = value { hasNoValue = true } else { hasNoValue = false }
        let workTask = hasNoValue ? self.workTask : nil
        self.workTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        workTask?.cancel()
        continuation?.resume(returning: value)
    }
}
