import XCTest
@testable import V2rayMKit

private actor ModeHarness: ProxyModeBackend, ProxyModePreferences {
    var tun: MacTunStatus
    var proxy: Bool
    var events: [String] = []
    var failTunOnce = false
    var failStart = false
    init(system: Bool = false, tunnel: Bool = false, failTunOnce: Bool = false, failStart: Bool = false) throws {
        tun = try JSONDecoder().decode(MacTunStatus.self, from: Data("""
        {"platformSupported":true,"helperAvailable":true,"helperCode":"ok","helperState":"ready","enabled":\(tunnel),"supportedCores":["xray","sing_box"],"coreSource":"test","runtimeState":"\(system || tunnel ? "running" : "stopped")","privilegedCoreProcessIds":\(tunnel ? "[42]" : "[]")}
        """.utf8))
        proxy = system; self.failTunOnce = failTunOnce; self.failStart = failStart
    }
    func tunStatus() -> MacTunStatus { events.append("status"); return tun }
    func setTunEnabled(_ enabled: Bool) throws {
        events.append(enabled ? "tun-on" : "tun-off")
        if enabled && failTunOnce { failTunOnce = false; throw ClientFailure("mac_tun_apply_failed") }
        if enabled && proxy { throw ClientFailure("modes_overlap") }
        tun.enabled = enabled
        if tun.runtimeState == "running" { tun.privilegedCoreProcessIds = enabled ? [42] : [] }
    }
    func startTunCore() throws {
        events.append("start")
        if failStart { throw ClientFailure("core_start_failed") }
        tun.runtimeState = "running"; tun.privilegedCoreProcessIds = tun.enabled ? [42] : []
    }
    func stopProxyCore() { events.append("stop"); tun.runtimeState = "stopped"; tun.privilegedCoreProcessIds = [] }
    func proxyConnection() -> ProxyConnection { ProxyConnection(running: tun.runtimeState == "running", port: 10808) }
    func enableProxy(port: Int) throws {
        events.append("proxy-on")
        if tun.enabled || tun.runtimeState != "running" { throw ClientFailure("modes_overlap") }
        proxy = true
    }
    func restoreProxy() { events.append("proxy-off"); proxy = false }
}

final class ProxyModeSwitchTests: XCTestCase {
    func testSystemToTunRestoresPreferencesBeforeEnablingTheTunnel() async throws {
        let h = try ModeHarness(system: true)
        let enabled = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: true, hasSelectedProfile: true,
            backend: h, preferences: h, checkOtherTunnel: {})
        XCTAssertFalse(enabled)
        let state = await h.tun, proxy = await h.proxy, events = await h.events
        XCTAssertTrue(state.isRunning); XCTAssertFalse(proxy)
        XCTAssertLessThan(events.firstIndex(of: "proxy-off")!, events.firstIndex(of: "tun-on")!)
    }
    func testTunToSystemStopsTheTunnelBeforeStartingTheListenerAndProxy() async throws {
        let h = try ModeHarness(tunnel: true)
        let enabled = try await ProxyModeSwitch.apply(.system, systemProxyEnabled: false, hasSelectedProfile: true, backend: h, preferences: h)
        let state = await h.tun, events = await h.events
        XCTAssertTrue(enabled); XCTAssertFalse(state.enabled); XCTAssertEqual(state.runtimeState, "running")
        XCTAssertLessThan(events.firstIndex(of: "stop")!, events.firstIndex(of: "tun-off")!)
        XCTAssertLessThan(events.firstIndex(of: "start")!, events.firstIndex(of: "proxy-on")!)
    }
    func testTurningOffStopsTheCoreAndClearsSavedTunIntent() async throws {
        let h = try ModeHarness(tunnel: true)
        let enabled = try await ProxyModeSwitch.apply(.off, systemProxyEnabled: false, hasSelectedProfile: false, backend: h, preferences: h)
        let state = await h.tun
        XCTAssertFalse(enabled); XCTAssertFalse(state.enabled); XCTAssertEqual(state.runtimeState, "stopped")
    }
    func testConflictDoesNotDisturbTheWorkingSystemProxy() async throws {
        let h = try ModeHarness(system: true)
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: true, hasSelectedProfile: true,
                backend: h, preferences: h, checkOtherTunnel: { throw ClientFailure("tun_conflict") })
            XCTFail("Conflict must be rejected")
        } catch { XCTAssertEqual((error as? ClientFailure)?.code, "tun_conflict") }
        let proxy = await h.proxy, events = await h.events
        XCTAssertTrue(proxy); XCTAssertEqual(events, ["status"])
    }
    func testFailedTunnelTransitionRestoresTheOriginalSystemMode() async throws {
        let h = try ModeHarness(system: true, failTunOnce: true)
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: true, hasSelectedProfile: true,
                backend: h, preferences: h, checkOtherTunnel: {})
            XCTFail("Failure must be reported")
        } catch let failure as ProxyModeFailure {
            XCTAssertTrue(failure.systemProxyEnabled); XCTAssertFalse(failure.rollbackFailed)
        }
        let proxy = await h.proxy, state = await h.tun
        XCTAssertTrue(proxy); XCTAssertFalse(state.enabled); XCTAssertEqual(state.runtimeState, "running")
    }
    func testFailedStartLeavesBothModesOff() async throws {
        let h = try ModeHarness(failStart: true)
        do {
            _ = try await ProxyModeSwitch.apply(.system, systemProxyEnabled: false, hasSelectedProfile: true, backend: h, preferences: h)
            XCTFail("Failure must be reported")
        } catch let failure as ProxyModeFailure { XCTAssertFalse(failure.systemProxyEnabled); XCTAssertFalse(failure.rollbackFailed) }
        let proxy = await h.proxy, state = await h.tun
        XCTAssertFalse(proxy); XCTAssertFalse(state.enabled); XCTAssertEqual(state.runtimeState, "stopped")
    }
    func testRollbackFailureIsReportedWithoutClaimingTheOldProxyWasRestored() async throws {
        let h = try ModeHarness(system: true, failTunOnce: true, failStart: true)
        do {
            _ = try await ProxyModeSwitch.apply(.tun, systemProxyEnabled: true, hasSelectedProfile: true,
                backend: h, preferences: h, checkOtherTunnel: {})
            XCTFail("Failure must be reported")
        } catch let failure as ProxyModeFailure { XCTAssertTrue(failure.rollbackFailed); XCTAssertFalse(failure.systemProxyEnabled) }
    }
}
