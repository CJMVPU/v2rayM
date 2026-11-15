public struct RecoveryObservation {
    public var awake: Bool
    public var networkAvailable: Bool
    public var desiredMode: ProxyMode
    public var systemProxyEnabled: Bool
    public var tunEnabled: Bool
    public var tunRunning: Bool
    public var coreRunning: Bool
    public var runtimeState: String
    public var coreStartedAt: String?
    public var updating: Bool
    public var proxyNeedsRecovery: Bool

    public init(awake: Bool, networkAvailable: Bool, desiredMode: ProxyMode,
                systemProxyEnabled: Bool, tunEnabled: Bool, tunRunning: Bool,
                coreRunning: Bool, runtimeState: String, coreStartedAt: String?,
                updating: Bool, proxyNeedsRecovery: Bool) {
        self.awake = awake; self.networkAvailable = networkAvailable; self.desiredMode = desiredMode
        self.systemProxyEnabled = systemProxyEnabled; self.tunEnabled = tunEnabled; self.tunRunning = tunRunning
        self.coreRunning = coreRunning; self.runtimeState = runtimeState; self.coreStartedAt = coreStartedAt
        self.updating = updating; self.proxyNeedsRecovery = proxyNeedsRecovery
    }

    public var modeHealthy: Bool {
        guard coreRunning else { return false }
        switch desiredMode {
        case .off: return false
        case .system: return systemProxyEnabled && !tunEnabled
        case .tun: return tunRunning && !systemProxyEnabled
        }
    }
    public var coreStopped: Bool { !coreRunning && ["stopped", "faulted"].contains(runtimeState) }
}
