/// User intent is independent of whether the requested listener is currently up.
/// An observation started before a mutation cannot change the new connection.
public struct ConnectionCoordinator {
    public private(set) var desiredMode: ProxyMode = .off
    public private(set) var revision = 0
    public var recovery = NetworkRecovery()
    public init() {}
    public var requested: Bool { desiredMode != .off }
    public mutating func invalidateObservations() { revision += 1 }
    public mutating func request(_ mode: ProxyMode) {
        desiredMode = mode; invalidateObservations(); recovery.cancel()
    }
    public mutating func restoreIntent(_ mode: ProxyMode) { desiredMode = mode }
    public func isCurrent(revision: Int, recoveryGeneration: Int) -> Bool {
        self.revision == revision && recovery.generation == recoveryGeneration
    }
}
