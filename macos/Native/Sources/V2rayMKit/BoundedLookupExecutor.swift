import Foundation

/// Blocking system resolvers run outside Swift's cooperative pool. Timed-out work
/// retains its slot until it really exits, so repeated timeouts cannot grow a queue.
public final class BoundedLookupExecutor: @unchecked Sendable {
    private let slots: DispatchSemaphore
    private let queue = DispatchQueue(label: "v2rayM.lookup", qos: .utility, attributes: .concurrent)
    private let timeout: TimeInterval
    public init(concurrency: Int = 2, timeout: TimeInterval = 3) {
        slots = DispatchSemaphore(value: max(1, concurrency)); self.timeout = max(0, timeout)
    }
    public func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value?) async -> Value? {
        let result = LookupResult<Value>()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                result.install(continuation)
                guard !Task.isCancelled, slots.wait(timeout: .now()) == .success else {
                    result.finish(nil); return
                }
                let deadline = DispatchWorkItem { result.finish(nil) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                queue.async { [slots] in
                    defer { slots.signal(); deadline.cancel() }
                    guard !result.finished else { return }
                    result.finish(work())
                }
            }
        }, onCancel: { result.finish(nil) })
    }
}
private final class LookupResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var done = false
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func install(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        if done { lock.unlock(); continuation.resume(returning: nil) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ value: Value?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
