import Foundation

/// Receipts belong to a random start token, never a PID or a new XPC connection.
/// Unknown/evicted tokens (including after daemon restart) cannot prove cleanup.
public final class SessionRecoveryStore {
    private let lock = NSLock()
    private var receipts: [String: HelperResponse] = [:]
    private var completed: [String] = []
    private let capacity: Int
    public init(capacity: Int = 256) { self.capacity = capacity }

    public func begin(_ token: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let token, UUID(uuidString: token) != nil, receipts[token] == nil else { return false }
        // Never evict a pending owner. Reject excess sessions instead.
        while receipts.count >= capacity, !completed.isEmpty { receipts.removeValue(forKey: completed.removeFirst()) }
        guard receipts.count < capacity else { return false }
        receipts[token] = HelperResponse(success: false, code: "session_cleanup_pending", state: "stopping")
        return true
    }

    public func finish(_ token: String, confirmed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard receipts[token]?.code == "session_cleanup_pending" else { return }
        receipts[token] = confirmed
            ? HelperResponse(code: "session_cleanup_confirmed", state: "stopped")
            : HelperResponse(success: false, code: "session_cleanup_unconfirmed", state: "faulted")
        completed.append(token)
    }

    public func status(_ token: String?) -> HelperResponse {
        lock.lock(); defer { lock.unlock() }
        return token.flatMap { receipts[$0] }
            ?? HelperResponse(success: false, code: "session_cleanup_unknown", state: "unavailable")
    }
}
