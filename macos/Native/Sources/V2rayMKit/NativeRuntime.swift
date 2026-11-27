import Foundation
import V2rayMDomain
import V2rayMApplication

public enum NativeSettingsSection: String, Sendable {
    case inbound, core, application, speedTest, routing, coreTypes, apply, simpleDNS, webDAV, nativeTun
}
public enum NativeEditorResource: String, Sendable {
    case dnsOptions = "dns-options", dnsDefaults = "dns-defaults", editorOptions = "editor-options"
}

/// Native orchestration depends on this contract, not on URLSession or a live process.
public protocol NativeAPI: ProxyModeBackend, NativeModuleUpdateRuntime {
    func geoUpdateProgress() async throws -> ModuleUpdateProgress?
    func restartCore() async throws
    func activeOperations() async throws -> [String]
    func runtimeStatus() async throws -> RuntimeStatus
    func logTail(after: Int64, limit: Int) async throws -> LogTail
    func profileMetadata() async throws -> [Profile]
    func profileObservations() async throws -> [ProfileObservation]
    func profileDocument(id: String) async throws -> SettingsValue
    @discardableResult func saveProfile(id: String, original: SettingsValue, edited: SettingsValue) async throws -> SettingsValue
    func routingProfiles() async throws -> [RoutingProfile]

    // Settings and routing
    func settings() async throws -> SettingsValue
    func settingsSection(_ section: NativeSettingsSection) async throws -> SettingsValue
    func saveSettings(_ section: NativeSettingsSection, _ input: SettingsValue) async throws
    func editorResource(_ resource: NativeEditorResource) async throws -> SettingsValue
    func configurationProfiles(_ kind: CoreConfigurationProfile) async throws -> SettingsValue
    func saveConfigurationProfile(_ kind: CoreConfigurationProfile, _ input: SettingsValue) async throws
    func applyRegion(_ name: String) async throws
    func routeDocuments() async throws -> SettingsValue
    func routingRules(id: String) async throws -> SettingsValue
    @discardableResult func saveRoute(id: String?, _ input: SettingsValue) async throws -> String
    func activateRoute(_ id: String) async throws
    func deleteRoute(_ id: String) async throws
    func importRoutes() async throws

    // Profiles
    func selectProfile(_ id: String, connect: Bool) async throws
    @discardableResult func importProfiles(_ content: String, group: String?, isSubscription: Bool) async throws -> Int
    @discardableResult func deleteProfiles(_ ids: [String]) async throws -> ProfileRemovalResult

    // Diagnostics
    func testLatency(_ id: String) async throws

    // Backup and restore
    func exportBackup() async throws -> Data
    @discardableResult func restoreBackup(_ data: Data) async throws -> SettingsValue
    func checkWebDAV() async throws
    func uploadBackup() async throws
    @discardableResult func restoreWebDAVBackup() async throws -> SettingsValue
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
