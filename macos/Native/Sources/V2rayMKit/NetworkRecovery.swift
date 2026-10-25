import Foundation

/// A generation prevents a check started before sleep/network change from
/// completing a newer recovery. Backoff also bounds retries of a slow backend.
public struct NetworkRecovery {
    public enum Action: Equatable { case wait, reconcileMode, restart, verify }
    public private(set) var active = false
    public private(set) var generation = 0
    public private(set) var needsRestart = false
    public private(set) var nextAttempt = Date.distantPast
    private var attempts = 0
    private var restartBaseline: String?
    private var restartSubmitted = false
    public init() {}
    public mutating func begin(restart: Bool, now: Date = Date()) {
        // Display/session resume is a health check. It must not invalidate a
        // restart already submitted for the same physical network generation.
        if active && !restart { return }
        generation += 1; active = true
        needsRestart = needsRestart || restart
        attempts = 0; nextAttempt = now.addingTimeInterval(3)
        restartSubmitted = false; restartBaseline = nil
    }
    public func action(desiredMode: ProxyMode, systemProxyEnabled: Bool, tunEnabled: Bool,
                       coreRunning: Bool, runtimeState: String, coreStartedAt: String?) -> Action {
        guard active, desiredMode != .off, !["starting", "stopping"].contains(runtimeState) else { return .wait }
        // User intent survives failed transitions and is not inferred from a
        // temporarily stopped process or from the persisted TUN switch.
        if desiredMode == .tun ? (!tunEnabled || systemProxyEnabled) : (tunEnabled || !systemProxyEnabled) {
            return .reconcileMode
        }
        let coreStopped = !coreRunning && ["stopped", "faulted"].contains(runtimeState)
        guard needsRestart || coreStopped else { return .verify }
        if restartSubmitted, coreRunning, let coreStartedAt, coreStartedAt != restartBaseline { return .verify }
        return .restart
    }
    public mutating func submitted(startedAt: String?, generation: Int) {
        guard self.generation == generation else { return }
        restartBaseline = startedAt; restartSubmitted = true
    }
    public mutating func restarted(generation: Int) {
        if self.generation == generation { needsRestart = false }
    }
    public mutating func complete(generation: Int) {
        guard self.generation == generation else { return }
        cancel()
    }
    public mutating func cancel() {
        generation += 1; active = false; needsRestart = false; attempts = 0
        restartSubmitted = false; restartBaseline = nil
    }
    public mutating func retry(now: Date = Date()) {
        attempts = min(attempts + 1, 5)
        nextAttempt = now.addingTimeInterval(min(30, pow(2, Double(attempts))))
    }
    public func canAttempt(awake: Bool, networkAvailable: Bool, now: Date = Date()) -> Bool {
        active && awake && networkAvailable && now >= nextAttempt
    }
    public static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? ProxyModeFailure {
            return !failure.rollbackFailed && isTransient(failure.underlying)
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .cancelled].contains(error.code)
    }
}
