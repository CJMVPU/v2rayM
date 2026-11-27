import XCTest
@testable import V2rayMKit

private func tunState(enabled: Bool = false, available: Bool = true, running: Bool = false, pids: [Int] = []) -> MacTunStatus {
    MacTunStatus(platformSupported: true, helperAvailable: available, helperCode: available ? "ok" : "helper_unavailable",
                 helperState: available ? "idle" : "unavailable", enabled: enabled, supportedCores: ["xray"],
                 coreSource: "signed-app-bundle", runtimeState: running ? "running" : "stopped", privilegedCoreProcessIds: pids)
}

private actor MemoryTunBackend: ProxyModeBackend, ProxyModePreferences {
    var state: MacTunStatus
    var calls: [String] = []
    let failEnable: Bool
    let failStart: Bool
    let failRollback: Bool
    init(_ state: MacTunStatus, failEnable: Bool = false, failStart: Bool = false, failRollback: Bool = false) {
        self.state = state; self.failEnable = failEnable; self.failStart = failStart; self.failRollback = failRollback
    }
    func tunStatus(_ mode: TunStatusReadMode) async throws -> MacTunStatus { calls.append("status"); return state }
    func setTunEnabled(_ enabled: Bool) async throws {
        calls.append(enabled ? "enable" : "disable")
        if enabled && failEnable || !enabled && failRollback { throw ClientFailure("mac_tun_apply_failed") }
        state.enabled = enabled
        if state.runtimeState == "running" { state.privilegedCoreProcessIds = enabled ? [42] : [] }
    }
    func startCore() async throws {
        calls.append("start")
        if failStart { throw ClientFailure("core_start_failed") }
        state.runtimeState = "running"; state.privilegedCoreProcessIds = state.enabled ? [42] : []
    }
    func stopCore() { calls.append("stop"); state.runtimeState = "stopped"; state.privilegedCoreProcessIds = [] }
    func proxyConnection() -> ProxyConnection { ProxyConnection(running: state.runtimeState == "running", port: 10808) }
    func enableProxy(endpoints: ProxyEndpoints) {}
    func restoreProxy() {}
}

final class TunModeTests: XCTestCase {
    func testDisconnectedEnableStartsTheSelectedNode() async throws {
        let backend = MemoryTunBackend(tunState())
        _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend, checkOtherTunnel: {})
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status", "enable", "start", "status"])
    }
    func testRunningModeChangeUsesBackendRestartTransaction() async throws {
        let backend = MemoryTunBackend(tunState(running: true))
        _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend, checkOtherTunnel: {})
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status", "enable", "status"])
    }
    func testDisableWorksWithoutHelperOrSelectedNode() async throws {
        let backend = MemoryTunBackend(tunState(enabled: true, available: false))
        _ = try await ProxyModeSwitch.apply(.off, systemProxyEnabled: false, hasSelectedProfile: false, backend: backend, preferences: backend,
                                     checkOtherTunnel: { throw ClientFailure("tun_conflict") })
        let calls = await backend.calls
        XCTAssertEqual(calls, ["stop", "disable"])
    }
    func testMissingNodeCannotChangeSavedMode() async throws {
        let backend = MemoryTunBackend(tunState())
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: false, backend: backend, preferences: backend, checkOtherTunnel: {})
            XCTFail("Missing node must be rejected")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "profile_not_selected") }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status"])
    }
    func testMissingHelperCannotEnableOrStart() async throws {
        let backend = MemoryTunBackend(tunState(available: false))
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend, checkOtherTunnel: {})
            XCTFail("Missing helper must be rejected")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "mac_tun_helper_unavailable") }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status"])
    }
    func testAnotherTunnelCannotBeOverwritten() async throws {
        let backend = MemoryTunBackend(tunState())
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend,
                                         checkOtherTunnel: { throw ClientFailure("tun_conflict") })
            XCTFail("Existing tunnel must be rejected")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "tun_conflict") }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status"])
    }
    func testFailedStartRestoresPreviouslyDisabledMode() async throws {
        let backend = MemoryTunBackend(tunState(), failStart: true)
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend, checkOtherTunnel: {})
            XCTFail("Failed start must be reported")
        } catch let failure as ProxyModeFailure { XCTAssertEqual((failure.underlying as? ClientFailure)?.code, "core_start_failed"); XCTAssertFalse(failure.rollbackFailed) }
        let calls = await backend.calls
        let state = await backend.state
        XCTAssertEqual(calls, ["status", "enable", "start", "stop", "disable"])
        XCTAssertFalse(state.enabled)
    }
    func testFailedRollbackDoesNotClaimOriginalModeWasRestored() async throws {
        let backend = MemoryTunBackend(tunState(), failStart: true, failRollback: true)
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend, checkOtherTunnel: {})
            XCTFail("Failed rollback must be reported")
        } catch let failure as ProxyModeFailure { XCTAssertTrue(failure.rollbackFailed) }
    }
    func testFailedReconnectClearsNonrunningTunnelAfterRollback() async throws {
        let backend = MemoryTunBackend(tunState(enabled: true), failStart: true)
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend, checkOtherTunnel: {})
            XCTFail("Failed reconnect must be reported")
        } catch let failure as ProxyModeFailure { XCTAssertEqual((failure.underlying as? ClientFailure)?.code, "core_start_failed"); XCTAssertFalse(failure.rollbackFailed) }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status", "enable", "start", "stop", "disable"])
        let state = await backend.state
        XCTAssertFalse(state.enabled)
    }
    func testBackendApplyFailureRollsBackWithoutStartingStoppedMode() async throws {
        let backend = MemoryTunBackend(tunState(running: true), failEnable: true)
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend, checkOtherTunnel: {})
            XCTFail("Backend failure must be reported")
        } catch let failure as ProxyModeFailure { XCTAssertEqual((failure.underlying as? ClientFailure)?.code, "mac_tun_apply_failed") }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status", "enable", "stop", "disable"])
    }
    func testOwnRunningTunnelIsNotMistakenForAnotherApp() async throws {
        let backend = MemoryTunBackend(tunState(enabled: true, running: true, pids: [42]))
        _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: false, hasSelectedProfile: true, backend: backend, preferences: backend,
                                     checkOtherTunnel: { throw ClientFailure("tun_conflict") })
    }
    func testReconnectAlsoChecksForOtherTunnels() async throws {
        let backend = MemoryTunBackend(tunState(enabled: true))
        do {
            try await TunModeChange.checkBeforeConnecting(backend: backend,
                                                          checkOtherTunnel: { throw ClientFailure("tun_conflict") })
            XCTFail("Reconnect must not bypass the conflict check")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "tun_conflict") }
    }
    func testSavedIntentAloneDoesNotDisplayRunningTun() throws {
        let state = tunState(enabled: true)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.modeDescription, "已启用，未连接")
        XCTAssertFalse(tunState(enabled: true, running: true).isRunning)
        XCTAssertTrue(tunState(enabled: true, running: true, pids: [42]).isRunning)
    }
}
