import Foundation

/// Shutdown has a finite deadline because launchd may forcibly terminate the job.
/// The caller must retain session owners until this returns true or the process
/// exits, and report a false result as unconfirmed network recovery.
public enum SessionShutdownCoordinator {
    public static func stop(_ cleanups: [() -> Bool], timeout: TimeInterval = 20,
                            retryDelay: TimeInterval = 0.1) -> Bool {
        guard !cleanups.isEmpty else { return true }
        guard timeout > 0 else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let group = DispatchGroup()
        let result = ShutdownResult()
        for cleanup in cleanups {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if cleanup() { return }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining > 0 { Thread.sleep(forTimeInterval: min(retryDelay, remaining)) }
                }
                result.fail()
            }
        }
        return group.wait(timeout: .now() + timeout) == .success && result.success
    }
}

private final class ShutdownResult {
    private let lock = NSLock()
    private var failed = false
    func fail() { lock.lock(); failed = true; lock.unlock() }
    var success: Bool { lock.lock(); defer { lock.unlock() }; return !failed }
}
