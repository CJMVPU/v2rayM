import Foundation
import V2rayMDomain
import V2rayMApplication

/// Native orchestration depends on this contract, not on URLSession or a live process.
public protocol NativeAPI: ProxyModeBackend {
    func encodedResponse(_ path: String, method: String, body: Data?) async throws -> Data
}
extension NativeAPI {
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
extension APIClient: NativeAPI {}

public protocol NativeBackend: Sendable {
    var isRunning: Bool { get async }
    func startClient() async throws -> any NativeAPI
    func stop() async throws
}
extension BackendController: NativeBackend {
    public func startClient() async throws -> any NativeAPI { try await start() }
}
public protocol NativeProxy: ProxyModePreferences {
    var isEnabled: Bool { get async }
    var needsRecovery: Bool { get async }
    func rebind(port: Int) async throws
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
