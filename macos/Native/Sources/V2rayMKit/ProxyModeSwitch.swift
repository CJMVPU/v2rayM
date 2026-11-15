import Foundation
import V2rayMDomain
import V2rayMApplication

public typealias ProxyMode = V2rayMDomain.ProxyMode
public typealias ProxyConnection = V2rayMDomain.ProxyConnection
public typealias ProxyModePreferences = V2rayMApplication.ProxyModePreferences
public protocol ProxyModeBackend: TunBackend {
    func proxyConnection() async throws -> ProxyConnection
    func stopProxyCore() async throws
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
    public static func apply(_ target: ProxyMode, systemProxyEnabled: Bool, hasSelectedProfile: Bool,
                             backend: any ProxyModeBackend, preferences: any ProxyModePreferences,
                             checkOtherTunnel: @Sendable () async throws -> Void = { try await TunnelConflict.check() }) async throws -> Bool {
        do {
            return try await ProxyModeService.apply(target, systemProxyEnabled: systemProxyEnabled,
                hasSelectedProfile: hasSelectedProfile, backend: ModeBackendAdapter(backend: backend),
                preferences: preferences, checkOtherTunnel: checkOtherTunnel)
        } catch let failure as ModeSwitchFailure {
            throw ProxyModeFailure(systemProxyEnabled: failure.systemProxyEnabled,
                rollbackFailed: failure.rollbackFailed, underlying: presentationError(failure.underlying))
        } catch { throw presentationError(error) }
    }
    private static func presentationError(_ error: Error) -> Error {
        guard let rejection = error as? ModeSwitchRejection else { return error }
        switch rejection {
        case .profileNotSelected: return ClientFailure("profile_not_selected")
        case .helperUnavailable: return ClientFailure("mac_tun_helper_unavailable")
        case .coreStartFailed: return ClientFailure("core_start_failed")
        }
    }
    private struct ModeBackendAdapter: ProxyModeRuntime {
        let backend: any ProxyModeBackend
        func tunState() async throws -> TunModeState {
            let state = try await backend.tunStatus()
            return state.domainState
        }
        func proxyConnection() async throws -> ProxyConnection { try await backend.proxyConnection() }
        func stopProxyCore() async throws { try await backend.stopProxyCore() }
        func setTunEnabled(_ enabled: Bool) async throws { try await backend.setTunEnabled(enabled) }
        func startTunCore() async throws { try await backend.startTunCore() }
    }
}
