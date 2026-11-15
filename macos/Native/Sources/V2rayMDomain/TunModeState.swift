public struct ProxyConnection {
    public var running: Bool
    public var port: Int?
    public init(running: Bool, port: Int?) { self.running = running; self.port = port }
}

public struct TunModeState {
    public let helperAvailable: Bool
    public let enabled: Bool
    public let runtimeState: String
    public let ownedProcessIDs: [Int]
    public init(helperAvailable: Bool, enabled: Bool, runtimeState: String, ownedProcessIDs: [Int]) {
        self.helperAvailable = helperAvailable; self.enabled = enabled
        self.runtimeState = runtimeState; self.ownedProcessIDs = ownedProcessIDs
    }
    public var isRunning: Bool { enabled && runtimeState == "running" && !ownedProcessIDs.isEmpty }
    public var shouldDisableIdleIntent: Bool { enabled && !isRunning }
    public func connectionAdmission(requestingTun: Bool) -> TunConnectionAdmission {
        guard requestingTun else { return .allowed }
        guard helperAvailable else { return .helperRequired }
        return ownedProcessIDs.isEmpty ? .checkOtherTunnel : .allowed
    }
}

public enum TunConnectionAdmission { case allowed, helperRequired, checkOtherTunnel }
