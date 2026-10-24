import Foundation

/// Connection cancellation is independent of its request queue, so invalidation
/// can interrupt staging even while that queue is waiting on a network/tool call.
public final class HelperCancellation {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public final class HelperOperationContext {
    public static let stageTimeout: TimeInterval = 100
    public static let stageClientTimeout: TimeInterval = 110
    private let cancellation: HelperCancellation
    private let deadline: TimeInterval
    public init(timeout: TimeInterval = HelperOperationContext.stageTimeout,
                cancellation: HelperCancellation = HelperCancellation()) {
        self.cancellation = cancellation
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }
    public func check() throws {
        if cancellation.isCancelled { throw HelperFailure("update_cancelled") }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw HelperFailure("update_timeout") }
    }
}
