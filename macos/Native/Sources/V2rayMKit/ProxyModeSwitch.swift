import Foundation

public enum ProxyMode: Equatable, Sendable { case off, system, tun }
public struct ProxyConnection {
    public var running: Bool
    public var port: Int?
    public init(running: Bool, port: Int?) { self.running = running; self.port = port }
}
public protocol ProxyModeBackend: TunBackend {
    func proxyConnection() async throws -> ProxyConnection
    func stopProxyCore() async throws
}
public protocol ProxyModePreferences: Sendable {
    func enableProxy(port: Int) async throws
    func restoreProxy() async throws
}
extension APIClient: ProxyModeBackend {
    public func proxyConnection() async throws -> ProxyConnection {
        let state: RuntimeStatus = try await value("/api/status")
        return ProxyConnection(running: state.coreRunning, port: state.runningProxyPort)
    }
    public func stopProxyCore() async throws { try await perform("/api/core/stop") }
}
extension SystemProxyController: ProxyModePreferences {
    public func enableProxy(port: Int) throws { try enable(port: port) }
    public func restoreProxy() throws { _ = try restore() }
}
public struct ProxyModeFailure: LocalizedError {
    public let systemProxyEnabled: Bool
    public let rollbackFailed: Bool
    public let underlying: Error
    public var errorDescription: String? {
        rollbackFailed ? "模式切换失败，且恢复原模式未完成。请查看日志并关闭代理后重试。" : underlying.localizedDescription
    }
}

public enum ProxyModeSwitch {
    /// Modes have a single owner. Restore system preferences before stopping their
    /// listener, and preflight TUN before disturbing a working system proxy.
    public static func apply(_ target: ProxyMode, systemProxyEnabled: Bool, hasSelectedProfile: Bool,
                             backend: any ProxyModeBackend, preferences: any ProxyModePreferences,
                             checkOtherTunnel: @Sendable () async throws -> Void = { try await TunnelConflict.check() }) async throws -> Bool {
        let original = try await backend.tunStatus()
        let previous: ProxyMode = systemProxyEnabled ? .system : original.isRunning ? .tun : .off
        if target != .off && !hasSelectedProfile { throw ClientFailure("profile_not_selected") }
        if target == .tun {
            guard original.helperAvailable else { throw ClientFailure("mac_tun_helper_unavailable") }
            if original.privilegedCoreProcessIds.isEmpty { try await checkOtherTunnel() }
        }
        var proxyEnabled = systemProxyEnabled
        do {
            switch target {
            case .off:
                try await preferences.restoreProxy(); proxyEnabled = false
                try await backend.stopProxyCore()
                try await backend.setTunEnabled(false)
            case .system:
                if original.enabled {
                    try await backend.stopProxyCore()
                    try await backend.setTunEnabled(false)
                }
                try await backend.startTunCore()
                let state = try await backend.proxyConnection()
                guard state.running, let port = state.port else { throw ClientFailure("core_start_failed") }
                if !proxyEnabled { try await preferences.enableProxy(port: port); proxyEnabled = true }
            case .tun:
                try await preferences.restoreProxy(); proxyEnabled = false
                try await backend.setTunEnabled(true)
                if original.runtimeState != "running" { try await backend.startTunCore() }
                guard try await backend.tunStatus().isRunning else { throw ClientFailure("core_start_failed") }
            }
            return proxyEnabled
        } catch {
            let failure = error
            do {
                try await preferences.restoreProxy(); proxyEnabled = false
                try await backend.stopProxyCore()
                try await backend.setTunEnabled(previous == .tun)
                if previous != .off { try await backend.startTunCore() }
                if previous == .system {
                    let state = try await backend.proxyConnection()
                    guard state.running, let port = state.port else { throw ClientFailure("core_start_failed") }
                    try await preferences.enableProxy(port: port); proxyEnabled = true
                }
                if previous == .tun {
                    let restored = try await backend.tunStatus()
                    guard restored.isRunning else { throw ClientFailure("core_start_failed") }
                }
            } catch {
                throw ProxyModeFailure(systemProxyEnabled: proxyEnabled, rollbackFailed: true, underlying: failure)
            }
            throw ProxyModeFailure(systemProxyEnabled: proxyEnabled, rollbackFailed: false, underlying: failure)
        }
    }
}
