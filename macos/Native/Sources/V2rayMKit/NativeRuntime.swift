import Foundation
import V2rayMDomain
import V2rayMApplication

/// Native orchestration depends on this contract, not on URLSession or a live process.
public protocol NativeAPI: ProxyModeBackend {
    func runtimeStatus() async throws -> RuntimeStatus
    func logTail(after: Int64, limit: Int) async throws -> LogTail
    func profileMetadata() async throws -> [Profile]
    func profileObservations() async throws -> [ProfileObservation]
    func profileDocument(id: String) async throws -> SettingsValue
    @discardableResult func saveProfile(id: String, original: SettingsValue, edited: SettingsValue) async throws -> SettingsValue
    func routingProfiles() async throws -> [RoutingProfile]
    func encodedResponse(_ path: String, method: String, body: Data?) async throws -> Data
}
extension NativeAPI {
    public func runtimeStatus() async throws -> RuntimeStatus { try await value("/api/status") }
    public func logTail(after: Int64, limit: Int) async throws -> LogTail {
        try await value("/api/logs/tail?after=\(after)&limit=\(limit)")
    }
    public func profileMetadata() async throws -> [Profile] {
        try await value("/api/profiles?subscriptionId=&includeStatistics=false")
    }
    public func profileObservations() async throws -> [ProfileObservation] {
        try await value("/api/profiles/observations")
    }
    public func profileDocument(id: String) async throws -> SettingsValue {
        try await value("/api/profiles/\(id)")
    }
    @discardableResult public func saveProfile(id: String, original: SettingsValue, edited: SettingsValue) async throws -> SettingsValue {
        try await send("/api/profiles/\(id)", method: "PUT", body: edited)
        return edited
    }
    public func routingProfiles() async throws -> [RoutingProfile] {
        try await value("/api/settings/routing-profiles")
    }
    public func freshTunStatus() async throws -> MacTunStatus {
        try await value("/api/macos/tun?fresh=true")
    }
    public func value<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await encodedResponse(path, method: "GET", body: nil)
        let envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: data)
        guard let value = envelope.data else { throw ClientFailure("response_missing") }
        return value
    }
    public func perform(_ path: String, method: String = "POST") async throws {
        _ = try await encodedResponse(path, method: method, body: nil)
    }
    public func send<T: Encodable>(_ path: String, method: String = "POST", body: T) async throws {
        _ = try await encodedResponse(path, method: method, body: JSONEncoder().encode(body))
    }
}

public protocol NativeBackend: Sendable {
    var isRunning: Bool { get async }
    func startClient() async throws -> any NativeAPI
    func stop() async throws
}
public protocol NativeProxy: ProxyModePreferences {
    var isEnabled: Bool { get async }
    var needsRecovery: Bool { get async }
    func rebind(endpoints: ProxyEndpoints) async throws
    func restore() async throws -> Bool
}
extension SystemProxyController: NativeProxy {}

public typealias NativeClock = V2rayMApplication.NativeClock
public typealias ObservationScheduler = V2rayMApplication.ObservationScheduler
public struct SystemNativeClock: NativeClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

public typealias ConnectionCoordinator = V2rayMDomain.ConnectionCoordinator

extension ConnectionCoordinator {
    public static func shouldDetachSystemProxy(_ state: RuntimeStatus) -> Bool {
        !state.coreRunning && ["stopped", "faulted"].contains(state.runtimeState)
    }
}
