import Foundation

/// A generation prevents a check started before sleep/network change from
/// completing a newer recovery. Backoff also bounds retries of a slow backend.
public struct NetworkRecovery {
    public private(set) var active = false
    public private(set) var generation = 0
    public private(set) var needsRestart = false
    public private(set) var nextAttempt = Date.distantPast
    private var attempts = 0
    public init() {}
    public mutating func begin(restart: Bool, now: Date = Date()) {
        generation += 1; active = true
        needsRestart = needsRestart || restart
        attempts = 0; nextAttempt = now.addingTimeInterval(3)
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
    }
    public mutating func retry(now: Date = Date()) {
        attempts = min(attempts + 1, 4)
        nextAttempt = now.addingTimeInterval(min(30, pow(2, Double(attempts))))
    }
    public func canAttempt(awake: Bool, networkAvailable: Bool, now: Date = Date()) -> Bool {
        active && awake && networkAvailable && now >= nextAttempt
    }
    public static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .cancelled].contains(error.code)
    }
}
