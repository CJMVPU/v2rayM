import Foundation
import V2rayMDomain

public protocol ProxyModeRuntime: Sendable {
    func tunState() async throws -> TunModeState
    func proxyConnection() async throws -> ProxyConnection
    func stopProxyCore() async throws
    func setTunEnabled(_ enabled: Bool) async throws
    func startTunCore() async throws
}
public protocol ProxyModePreferences: Sendable {
    func enableProxy(endpoints: ProxyEndpoints) async throws
    func restoreProxy() async throws
}
public enum ModeSwitchRejection: Error { case profileNotSelected, helperUnavailable, coreStartFailed, proxyListenerUnavailable }
public struct ModeSwitchFailure: Error {
    public let systemProxyEnabled: Bool
    public let rollbackFailed: Bool
    public let underlying: Error
}

public enum ProxyModeService {
    /// Modes have a single owner. Restore system preferences before stopping their
    /// listener, and preflight TUN before disturbing a working system proxy.
    public static func apply(_ target: ProxyMode, systemProxyEnabled: Bool, hasSelectedProfile: Bool,
                             backend: any ProxyModeRuntime, preferences: any ProxyModePreferences,
                             checkOtherTunnel: @Sendable () async throws -> Void) async throws -> Bool {
        // Disconnect is monotonic: a failed observation/stop must never restart
        // the mode that the user explicitly turned off.
        if target == .off {
            var enabled = systemProxyEnabled
            do {
                try await preferences.restoreProxy(); enabled = false
                try await backend.stopProxyCore()
                try await backend.setTunEnabled(false)
                return false
            } catch {
                throw ModeSwitchFailure(systemProxyEnabled: enabled, rollbackFailed: false, underlying: error)
            }
        }
        let original = try await backend.tunState()
        let previous: ProxyMode = systemProxyEnabled ? .system : original.isRunning ? .tun : .off
        if target != .off && !hasSelectedProfile { throw ModeSwitchRejection.profileNotSelected }
        try await TunPreflightService.check(original, requestingTun: target == .tun, checkOtherTunnel: checkOtherTunnel)
        var proxyEnabled = systemProxyEnabled
        do {
            switch target {
            case .off:
                return false // Disconnect was handled before observing the old mode.
            case .system:
                if original.enabled {
                    try await backend.stopProxyCore()
                    try await backend.setTunEnabled(false)
                }
                try await backend.startTunCore()
                let state = try await backend.proxyConnection()
                guard state.running else { throw ModeSwitchRejection.coreStartFailed }
                guard let endpoints = state.endpoints, endpoints.preferredPort != nil else {
                    throw ModeSwitchRejection.proxyListenerUnavailable
                }
                if !proxyEnabled { try await preferences.enableProxy(endpoints: endpoints); proxyEnabled = true }
            case .tun:
                try await preferences.restoreProxy(); proxyEnabled = false
                try await backend.setTunEnabled(true)
                if original.runtimeState != "running" { try await backend.startTunCore() }
                guard try await backend.tunState().isRunning else { throw ModeSwitchRejection.coreStartFailed }
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
                    guard state.running, let endpoints = state.endpoints, endpoints.preferredPort != nil else { throw ModeSwitchRejection.coreStartFailed }
                    try await preferences.enableProxy(endpoints: endpoints); proxyEnabled = true
                }
                if previous == .tun {
                    let restored = try await backend.tunState()
                    guard restored.isRunning else { throw ModeSwitchRejection.coreStartFailed }
                }
            } catch {
                throw ModeSwitchFailure(systemProxyEnabled: proxyEnabled, rollbackFailed: true, underlying: failure)
            }
            throw ModeSwitchFailure(systemProxyEnabled: proxyEnabled, rollbackFailed: false, underlying: failure)
        }
    }
}
