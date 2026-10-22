import XCTest
@testable import V2rayMKit

private func tunState(enabled: Bool = false, available: Bool = true, running: Bool = false, pids: [Int] = []) throws -> MacTunStatus {
    let data = try JSONSerialization.data(withJSONObject: [
        "platformSupported": true, "helperAvailable": available, "helperCode": available ? "ok" : "helper_unavailable",
        "helperState": available ? "idle" : "unavailable", "enabled": enabled,
        "supportedCores": ["xray", "sing_box"], "coreSource": "signed-app-bundle",
        "runtimeState": running ? "running" : "stopped", "privilegedCoreProcessIds": pids,
    ])
    return try JSONDecoder().decode(MacTunStatus.self, from: data)
}

private actor MemoryTunBackend: TunBackend {
    var state: MacTunStatus
    var calls: [String] = []
    let failEnable: Bool
    let failStart: Bool
    let failRollback: Bool
    init(_ state: MacTunStatus, failEnable: Bool = false, failStart: Bool = false, failRollback: Bool = false) {
        self.state = state; self.failEnable = failEnable; self.failStart = failStart; self.failRollback = failRollback
    }
    func tunStatus() async throws -> MacTunStatus { calls.append("status"); return state }
    func setTunEnabled(_ enabled: Bool) async throws {
        calls.append(enabled ? "enable" : "disable")
        if enabled && failEnable || !enabled && failRollback { throw ClientFailure("mac_tun_apply_failed") }
        state.enabled = enabled
    }
    func startTunCore() async throws {
        calls.append("start")
        if failStart { throw ClientFailure("core_start_failed") }
    }
}

final class TunModeTests: XCTestCase {
    func testDisconnectedEnableStartsTheSelectedNode() async throws {
        let backend = MemoryTunBackend(try tunState())
        try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true, checkOtherTunnel: {})
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status", "enable", "start"])
    }
    func testRunningModeChangeUsesBackendRestartTransaction() async throws {
        let backend = MemoryTunBackend(try tunState(running: true))
        try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true, checkOtherTunnel: {})
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status", "enable"])
    }
    func testDisableWorksWithoutHelperOrSelectedNode() async throws {
        let backend = MemoryTunBackend(try tunState(enabled: true, available: false))
        try await TunModeChange.apply(false, backend: backend, hasSelectedProfile: false,
                                     checkOtherTunnel: { throw ClientFailure("tun_conflict") })
        let calls = await backend.calls
        XCTAssertEqual(calls, ["disable"])
    }
    func testMissingNodeCannotChangeSavedMode() async throws {
        let backend = MemoryTunBackend(try tunState())
        do {
            try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: false, checkOtherTunnel: {})
            XCTFail("Missing node must be rejected")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "profile_not_selected") }
        let calls = await backend.calls
        XCTAssertTrue(calls.isEmpty)
    }
    func testMissingHelperCannotEnableOrStart() async throws {
        let backend = MemoryTunBackend(try tunState(available: false))
        do {
            try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true, checkOtherTunnel: {})
            XCTFail("Missing helper must be rejected")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "mac_tun_helper_unavailable") }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status"])
    }
    func testAnotherTunnelCannotBeOverwritten() async throws {
        let backend = MemoryTunBackend(try tunState())
        do {
            try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true,
                                         checkOtherTunnel: { throw ClientFailure("tun_conflict") })
            XCTFail("Existing tunnel must be rejected")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "tun_conflict") }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status"])
    }
    func testFailedStartRestoresPreviouslyDisabledMode() async throws {
        let backend = MemoryTunBackend(try tunState(), failStart: true)
        do {
            try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true, checkOtherTunnel: {})
            XCTFail("Failed start must be reported")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "core_start_failed") }
        let calls = await backend.calls
        let state = await backend.state
        XCTAssertEqual(calls, ["status", "enable", "start", "disable"])
        XCTAssertFalse(state.enabled)
    }
    func testFailedRollbackDoesNotClaimOriginalModeWasRestored() async throws {
        let backend = MemoryTunBackend(try tunState(), failStart: true, failRollback: true)
        do {
            try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true, checkOtherTunnel: {})
            XCTFail("Failed rollback must be reported")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "tun_rollback_failed") }
    }
    func testFailedReconnectPreservesPreviouslyEnabledIntent() async throws {
        let backend = MemoryTunBackend(try tunState(enabled: true), failStart: true)
        do {
            try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true, checkOtherTunnel: {})
            XCTFail("Failed reconnect must be reported")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "core_start_failed") }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status", "enable", "start"])
    }
    func testBackendApplyFailureDoesNotIssueAnExtraRestartOrRollback() async throws {
        let backend = MemoryTunBackend(try tunState(running: true), failEnable: true)
        do {
            try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true, checkOtherTunnel: {})
            XCTFail("Backend failure must be reported")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "mac_tun_apply_failed") }
        let calls = await backend.calls
        XCTAssertEqual(calls, ["status", "enable"])
    }
    func testOwnRunningTunnelIsNotMistakenForAnotherApp() async throws {
        let backend = MemoryTunBackend(try tunState(enabled: true, running: true, pids: [42]))
        try await TunModeChange.apply(true, backend: backend, hasSelectedProfile: true,
                                     checkOtherTunnel: { throw ClientFailure("tun_conflict") })
    }
    func testReconnectAlsoChecksForOtherTunnels() async throws {
        let backend = MemoryTunBackend(try tunState(enabled: true))
        do {
            try await TunModeChange.checkBeforeConnecting(backend: backend,
                                                          checkOtherTunnel: { throw ClientFailure("tun_conflict") })
            XCTFail("Reconnect must not bypass the conflict check")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "tun_conflict") }
    }
    func testSavedIntentAloneDoesNotDisplayRunningTun() throws {
        let state = try tunState(enabled: true)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.modeDescription, "已启用，未连接")
        XCTAssertFalse(try tunState(enabled: true, running: true).isRunning)
        XCTAssertTrue(try tunState(enabled: true, running: true, pids: [42]).isRunning)
    }
}
