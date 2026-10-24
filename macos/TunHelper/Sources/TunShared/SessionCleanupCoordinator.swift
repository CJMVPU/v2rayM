import Foundation

/// Retains disconnected sessions until cleanup succeeds. Each attempt is bounded
/// by TunSession's stop deadlines; retries are rate-limited, never dropped.
public final class SessionCleanupCoordinator {
    private let queue = DispatchQueue(label: "v2rayM.tun.cleanup")
    private var pending = Set<UUID>()
    private let retryDelay: TimeInterval

    public init(retryDelay: TimeInterval = 1) { self.retryDelay = retryDelay }

    public func disconnect(id: UUID, cleanup: @escaping () -> Bool, completion: @escaping () -> Void) {
        queue.async {
            guard self.pending.insert(id).inserted else { return }
            self.attempt(id: id, cleanup: cleanup, completion: completion)
        }
    }

    private func attempt(id: UUID, cleanup: @escaping () -> Bool, completion: @escaping () -> Void) {
        if cleanup() {
            pending.remove(id)
            completion()
        } else {
            queue.asyncAfter(deadline: .now() + retryDelay) {
                self.attempt(id: id, cleanup: cleanup, completion: completion)
            }
        }
    }
}
