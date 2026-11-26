public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public init(host: String, port: Int) { self.host = host; self.port = port }
}

public struct ProxyEndpoints: Codable, Equatable, Sendable {
    public let http: ProxyEndpoint?
    public let socks: ProxyEndpoint?
    public init(http: ProxyEndpoint?, socks: ProxyEndpoint?) { self.http = http; self.socks = socks }
    public init(loopbackPort port: Int) {
        let endpoint = ProxyEndpoint(host: "127.0.0.1", port: port)
        self.init(http: endpoint, socks: endpoint)
    }
    public var preferredPort: Int? { http?.port ?? socks?.port }
}

public struct ProxyConnection {
    public var running: Bool
    public var endpoints: ProxyEndpoints?
    public init(running: Bool, endpoints: ProxyEndpoints?) { self.running = running; self.endpoints = endpoints }
    public init(running: Bool, port: Int?) { self.init(running: running, endpoints: port.map(ProxyEndpoints.init(loopbackPort:))) }
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
