import V2rayMDomain

@MainActor public protocol NativeStartupRuntime: AnyObject {
    func inspectProxyRecovery() async
    func startBackend() async throws
    func readTunState() async throws -> TunModeState
    func disableIdleTunIntent() async throws
    func refresh() async throws
    var systemProxyEnabled: Bool { get }
    func restoreIntent(_ mode: ProxyMode)
    func connected()
    func stopAfterFailure() async
}

@MainActor public struct NativeStartupService {
    public init() {}
    public func connect(_ runtime: any NativeStartupRuntime) async throws {
        do {
            await runtime.inspectProxyRecovery()
            try await runtime.startBackend()
            var state = try await runtime.readTunState()
            if state.shouldDisableIdleIntent {
                try await runtime.disableIdleTunIntent()
                state = try await runtime.readTunState()
            }
            try await runtime.refresh()
            runtime.restoreIntent(runtime.systemProxyEnabled ? .system : state.enabled ? .tun : .off)
            runtime.connected()
        } catch {
            await runtime.stopAfterFailure()
            throw error
        }
    }
}
