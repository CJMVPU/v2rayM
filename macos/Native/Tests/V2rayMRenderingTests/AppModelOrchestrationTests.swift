import XCTest
import Foundation
import Combine
import V2rayMKit
@testable import V2rayM

private actor RuntimeFixtureAPI: NativeAPI {
    var running = false
    var stopTimeouts = 0
    var stopCalls = 0
    var failTunRead = false
    var tunEnabled = false
    var failures = Set<String>()
    var starts = 0
    var restarts = 0
    var startedAt = "2026-10-24T10:00:00Z"
    var loseRestartResponse = false
    var tasks: [String] = []
    var holdNextStatus = false
    var held: CheckedContinuation<Data, Never>?
    var heldData: Data?
    var holdNextRestart = false
    var restartHeld: CheckedContinuation<Void, Never>?
    var holdNextStart = false
    var startHeld: CheckedContinuation<Void, Never>?
    var freshTunReads = 0
    var losePostRestartObservation = false
    func loseObservationAfterRestart() { losePostRestartObservation = true }
    func holdRestart() { holdNextRestart = true }
    func restartIsHeld() -> Bool { restartHeld != nil }
    func releaseRestart() { restartHeld?.resume(); restartHeld = nil }
    func holdStart() { holdNextStart = true }
    func startIsHeld() -> Bool { startHeld != nil }
    func releaseStart() { startHeld?.resume(); startHeld = nil }
    func timeoutStops(_ count: Int) { stopTimeouts = count }
    func failTunObservation() { failTunRead = true }
    func fail(_ path: String) { failures.insert(path) }
    func recover(_ path: String) { failures.remove(path) }
    func faultCore() { running = false }
    func setTasks(_ values: [String]) { tasks = values }
    func holdStatus() { holdNextStatus = true }
    func statusIsHeld() -> Bool { held != nil }
    func releaseStatus() { held?.resume(returning: heldData!); held = nil; heldData = nil }
    func loseNextRestartResponse() { loseRestartResponse = true }
    func encodedResponse(_ path: String, method: String, body: Data?) async throws -> Data {
        if failures.contains(path) { throw ClientFailure("fixture_observation_failed") }
        var result: Any = [:]
        switch path {
        case "/api/status":
            result = ["coreRunning": running, "xrayAvailable": true, "runtimeState": running ? "running" : "stopped",
                      "currentProfileId": "fixture", "runningProfileId": "fixture", "runningProxyPort": 10808,
                      "coreStartedAt": startedAt] as [String: Any]
        case "/api/profiles?subscriptionId=", "/api/settings/routing-profiles", "/api/core-updates/progress": result = []
        case "/api/operations": result = tasks
        case "/api/macos/tun?fresh=true":
            freshTunReads += 1
            if losePostRestartObservation && restarts > 0 {
                losePostRestartObservation = false
                throw URLError(.timedOut)
            }
            return try JSONSerialization.data(withJSONObject: ["success": true, "data": tunObject()])
        case "/api/core/restart":
            restarts += 1; running = true; startedAt = "2026-10-24T10:00:0\(restarts)Z"
            if holdNextRestart {
                holdNextRestart = false
                await withCheckedContinuation { restartHeld = $0 }
            }
            if loseRestartResponse { loseRestartResponse = false; throw URLError(.timedOut) }
        case "/api/core/start": await startTunCore()
        case "/api/core/stop": try stopProxyCore()
        default:
            if path.hasPrefix("/api/logs/tail") { result = ["items": [], "latestSequence": 0, "generation": 0] as [String: Any] }
        }
        let data = try JSONSerialization.data(withJSONObject: ["success": true, "data": result])
        if path == "/api/status", holdNextStatus {
            holdNextStatus = false; heldData = data
            return await withCheckedContinuation { held = $0 }
        }
        return data
    }
    func tunStatus() throws -> MacTunStatus {
        if failTunRead { throw URLError(.timedOut) }
        return try JSONDecoder().decode(MacTunStatus.self, from: JSONSerialization.data(withJSONObject: tunObject()))
    }
    private func tunObject() -> [String: Any] {
        ["platformSupported": true, "helperAvailable": true, "helperCode": "ok",
            "helperState": "ready", "enabled": tunEnabled, "supportedCores": ["xray"], "coreSource": "fixture",
            "runtimeState": running ? "running" : "stopped", "privilegedCoreProcessIds": tunEnabled && running ? [42] : []]
    }
    func setTunEnabled(_ enabled: Bool) { tunEnabled = enabled }
    func startTunCore() async {
        starts += 1; running = true
        if holdNextStart {
            holdNextStart = false
            await withCheckedContinuation { startHeld = $0 }
        }
    }
    func stopProxyCore() throws {
        stopCalls += 1
        if stopTimeouts > 0 { stopTimeouts -= 1; throw URLError(.timedOut) }
        running = false
    }
    func proxyConnection() -> ProxyConnection { ProxyConnection(running: running, port: 10808) }
}
private actor RuntimeFixtureBackend: NativeBackend {
    let api: RuntimeFixtureAPI
    var isRunning = true
    init(_ api: RuntimeFixtureAPI) { self.api = api }
    func startClient() -> any NativeAPI { api }
    func stop() { isRunning = false }
}
private actor RuntimeFixtureProxy: NativeProxy {
    var isEnabled = false
    var needsRecovery = false
    var restores = 0
    func enableProxy(port: Int) { isEnabled = true }
    func restoreProxy() { restores += 1; isEnabled = false }
    func restore() -> Bool { restores += 1; isEnabled = false; return false }
    func rebind(port: Int) throws { if !isEnabled { throw ClientFailure("proxy_recovery") } }
}
private final class RuntimeFixtureClock: NativeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 100)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
    func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(3600)) }
}
@MainActor private final class RuntimeFixtureNetwork: NetworkEvents {
    var sleep: ((Bool) -> Void)?
    var change: ((Bool) -> Void)?
    func observe(sleep: @escaping @MainActor (Bool) -> Void, change: @escaping @MainActor (Bool) -> Void) {
        self.sleep = sleep; self.change = change
    }
}

@MainActor final class AppModelOrchestrationTests: XCTestCase {
    private func fixture() async -> (AppModel, RuntimeFixtureAPI, RuntimeFixtureBackend, RuntimeFixtureProxy, RuntimeFixtureClock, RuntimeFixtureNetwork) {
        let api = RuntimeFixtureAPI(), proxy = RuntimeFixtureProxy(), clock = RuntimeFixtureClock(), network = RuntimeFixtureNetwork()
        let backend = RuntimeFixtureBackend(api)
        let model = AppModel(backend: backend, proxy: proxy, clock: clock, network: network, checkTunnel: {})
        await model.connect(); await model.waitForObservations()
        return (model, api, backend, proxy, clock, network)
    }
    private func settle(_ model: AppModel) async {
        await model.waitForOperation()
        XCTAssertFalse(model.busy)
        await model.waitForObservations()
    }
    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected suspended fixture request")
    }
    func testEmptyLogPollDoesNotRepublishUnchangedLogDocument() async {
        let (model, _, _, _, _, _) = await fixture()
        var publications = 0
        let observation = model.$logs.dropFirst().sink { _ in publications += 1 }
        _ = try? await model.refresh(); await model.waitForObservations()
        XCTAssertNil(model.observationErrors["logs"])
        XCTAssertEqual(publications, 0)
        observation.cancel()
        _ = await model.shutdown()
    }
    func testMetadataAndRuntimeObservationFailuresDoNotDisconnectHealthyProxy() async {
        let (model, api, _, proxy, clock, _) = await fixture()
        model.toggleProxy(true); await settle(model)
        let before = await proxy.restores
        await api.fail("/api/settings/routing-profiles")
        clock.advance(31); await model.pollOnce(); await model.waitForObservations()
        XCTAssertNotNil(model.observationErrors["routes"])
        XCTAssertEqual(model.desiredMode, .system)
        await api.fail("/api/status")
        await model.pollOnce()
        XCTAssertNotNil(model.observationErrors["runtime"])
        let after = await proxy.restores
        XCTAssertEqual(before, after); XCTAssertTrue(model.systemProxyEnabled)
        _ = await model.shutdown()
    }
    func testObservationFailureAfterSuccessfulEnableDoesNotUndoTheCommand() async {
        let (model, api, _, proxy, _, _) = await fixture()
        await api.fail("/api/status")
        model.toggleProxy(true); await settle(model)
        XCTAssertEqual(model.desiredMode, .system)
        XCTAssertTrue(model.systemProxyEnabled)
        let enabled = await proxy.isEnabled
        XCTAssertTrue(enabled); XCTAssertNotNil(model.observationErrors["runtime"])
        _ = await model.shutdown()
    }
    func testOwnedBackendExitRestoresProxy() async {
        let (model, _, backend, proxy, _, _) = await fixture()
        model.toggleProxy(true); await settle(model)
        await backend.stop(); await model.pollOnce()
        XCTAssertFalse(model.ready); XCTAssertFalse(model.systemProxyEnabled)
        let enabled = await proxy.isEnabled; XCTAssertFalse(enabled)
        _ = await model.shutdown()
    }
    func testFaultedRequestedModeCanBeTurnedOff() async {
        let (model, api, _, _, _, _) = await fixture()
        model.toggleTun(true); await settle(model)
        await api.faultCore()
        _ = try? await model.refresh(); await model.waitForObservations()
        XCTAssertEqual(model.desiredMode, .tun)
        XCTAssertFalse(model.proxyRunning)
        model.toggleTun(false); await settle(model)
        XCTAssertEqual(model.desiredMode, .off)
        XCTAssertFalse(model.systemProxyEnabled)
        _ = await model.shutdown()
    }
    func testOldRuntimeResponseCannotOverwriteCompletedOffOperation() async {
        let (model, api, _, _, _, _) = await fixture()
        model.toggleProxy(true); await settle(model)
        await api.holdStatus()
        let old = Task { try? await model.refresh() }
        await waitUntil { await api.statusIsHeld() }
        model.toggleProxy(false); await settle(model)
        await api.releaseStatus(); _ = await old.value
        XCTAssertEqual(model.desiredMode, .off)
        XCTAssertFalse(model.status?.coreRunning ?? true)
        _ = await model.shutdown()
    }
    func testWakeRecoveryWaitsForUpdatesAndDoesNotRepeatAcceptedTimedOutRestart() async {
        let (model, api, _, _, clock, network) = await fixture()
        model.toggleProxy(true); await settle(model)
        network.sleep?(true); network.sleep?(false)
        clock.advance(4)
        await api.setTasks(["core-update-Xray"])
        await model.pollOnce()
        let before = await api.restarts; XCTAssertEqual(before, 0)
        await api.setTasks([]); await api.loseNextRestartResponse()
        await model.pollOnce()
        XCTAssertTrue(model.networkRecovery.active)
        clock.advance(31); await model.pollOnce()
        let after = await api.restarts
        XCTAssertEqual(after, 1); XCTAssertFalse(model.networkRecovery.active)
        XCTAssertNil(model.error)
        XCTAssertEqual(MenuBarMode(model.displayStatus(at: clock.now())), .system)
        XCTAssertEqual(model.desiredMode, .system)
        _ = await model.shutdown()
    }
    func testOffDuringRecoveryWaitsForAcceptedRestartThenStopsIt() async {
        let (model, api, _, proxy, clock, network) = await fixture()
        model.toggleProxy(true); await settle(model)
        network.sleep?(true); network.sleep?(false); clock.advance(4)
        await api.holdRestart()
        let recovery = Task { await model.pollOnce() }
        await waitUntil { await api.restartIsHeld() }
        XCTAssertTrue(model.canToggle(.system))
        model.toggleProxy(false)
        XCTAssertEqual(model.desiredMode, .off)
        XCTAssertFalse(model.networkRecovery.active)
        await api.releaseRestart(); await recovery.value; await settle(model)
        XCTAssertFalse(model.systemProxyEnabled)
        let running = await api.running, enabled = await proxy.isEnabled
        XCTAssertFalse(running); XCTAssertFalse(enabled)
        clock.advance(31); await model.pollOnce()
        let restarts = await api.restarts, freshReads = await api.freshTunReads
        XCTAssertEqual(restarts, 1); XCTAssertGreaterThan(freshReads, 0)
        _ = await model.shutdown()
    }
    func testShutdownWaitsForLateEnableThenRestoresBeforeCompleting() async {
        let (model, api, backend, proxy, _, _) = await fixture()
        await api.holdStart()
        model.toggleProxy(true)
        await waitUntil { await api.startIsHeld() }
        let exit = Task { await model.shutdown() }
        await Task.yield()
        await api.releaseStart()
        let completed = await exit.value
        XCTAssertTrue(completed); XCTAssertFalse(model.ready)
        XCTAssertEqual(model.desiredMode, .off)
        let enabled = await proxy.isEnabled, running = await backend.isRunning
        XCTAssertFalse(enabled); XCTAssertFalse(running)
        await model.waitForObservations()
        XCTAssertFalse(model.status?.coreRunning ?? true)
    }

    func testWifiReconnectPublishesMatchingHomeAndMenuStatesForBothModes() async {
        for mode in [ProxyMode.system, .tun] {
            let (model, api, _, _, clock, network) = await fixture()
            network.change?(true)
            if mode == .system { model.toggleProxy(true) } else { model.toggleTun(true) }
            await settle(model)
            network.change?(false)
            XCTAssertEqual(model.displayStatus(at: clock.now()), .recovering)
            XCTAssertEqual(MenuBarMode(model.displayStatus(at: clock.now())), .recovering)
            clock.advance(31); await model.pollOnce()
            let offlineRestarts = await api.restarts
            XCTAssertEqual(offlineRestarts, 0)
            network.change?(true)
            await model.pollOnce()
            let beforeDebounce = await api.restarts
            XCTAssertEqual(beforeDebounce, 0)
            clock.advance(4); await model.pollOnce(); await model.waitForObservations()
            XCTAssertFalse(model.networkRecovery.active)
            XCTAssertEqual(model.displayStatus(at: clock.now()), mode == .system ? .system : .tun)
            XCTAssertEqual(MenuBarMode(model.displayStatus(at: clock.now())), mode == .system ? .system : .tun)
            XCTAssertNil(model.error)
            _ = await model.shutdown()
        }
    }
    func testOffDuringDisconnectedWifiDoesNotNeedTunObservation() async {
        for mode in [ProxyMode.system, .tun] {
            let (model, api, _, _, clock, network) = await fixture()
            if mode == .system { model.toggleProxy(true) } else { model.toggleTun(true) }
            await settle(model)
            network.change?(false)
            await api.failTunObservation()
            if mode == .system { model.toggleProxy(false) } else { model.toggleTun(false) }
            await settle(model)
            XCTAssertEqual(model.desiredMode, .off)
            XCTAssertFalse(model.networkRecovery.active)
            let running = await api.running
            XCTAssertFalse(running); XCTAssertNil(model.error)
            network.change?(true); clock.advance(31); await model.pollOnce()
            let restarts = await api.restarts
            XCTAssertEqual(restarts, 0)
            XCTAssertEqual(MenuBarMode(model.displayStatus(at: clock.now())), .inactive)
            _ = await model.shutdown()
        }
    }
    func testStopTimeoutKeepsOffIntentRetriesAndNeverRestartsOldMode() async {
        for mode in [ProxyMode.system, .tun] {
            let (model, api, _, proxy, clock, network) = await fixture()
            if mode == .system { model.toggleProxy(true) } else { model.toggleTun(true) }
            await settle(model)
            let starts = await api.starts
            network.sleep?(true); network.sleep?(false)
            await api.timeoutStops(2)
            if mode == .system { model.toggleProxy(false) } else { model.toggleTun(false) }
            await settle(model)
            XCTAssertEqual(model.desiredMode, .off); XCTAssertNil(model.error)
            XCTAssertEqual(model.displayStatus(at: clock.now()), .changing)
            XCTAssertFalse(model.canToggle(.system)); XCTAssertFalse(model.canToggle(.tun))
            var mutationRan = false
            model.run { _ in mutationRan = true }; await model.waitForOperation()
            XCTAssertFalse(mutationRan)
            clock.advance(3); await model.pollOnce(); await settle(model)
            XCTAssertNil(model.error); XCTAssertEqual(model.desiredMode, .off)
            clock.advance(3); await model.pollOnce(); await settle(model)
            let afterStarts = await api.starts, restarts = await api.restarts
            let running = await api.running, enabled = await proxy.isEnabled
            XCTAssertEqual(afterStarts, starts); XCTAssertEqual(restarts, 0)
            XCTAssertFalse(running); XCTAssertFalse(enabled)
            XCTAssertEqual(model.displayStatus(at: clock.now()), .stopped)
            XCTAssertEqual(MenuBarMode(model.displayStatus(at: clock.now())), .inactive)
            XCTAssertNil(model.error); XCTAssertNil(model.observationErrors["disconnect"])
            _ = await model.shutdown()
        }
    }

    func testRecoveryRetriesCoreThatStopsAfterAcceptedRestart() async {
        let (model, api, _, _, clock, network) = await fixture()
        model.toggleProxy(true); await settle(model)
        network.sleep?(true); network.sleep?(false); clock.advance(4)
        await api.loseObservationAfterRestart()
        await model.pollOnce()
        XCTAssertTrue(model.networkRecovery.active); XCTAssertNil(model.error)
        await api.faultCore()
        clock.advance(31); await model.pollOnce()
        XCTAssertFalse(model.networkRecovery.active)
        XCTAssertEqual(model.displayStatus(at: clock.now()), .system)
        XCTAssertNil(model.error)
        _ = await model.shutdown()
    }

    func testOffWithLostObservationsDoesNotPublishOldRunningState() async {
        let (model, api, _, _, clock, network) = await fixture()
        model.toggleTun(true); await settle(model)
        network.change?(false)
        await api.fail("/api/status"); await api.failTunObservation()
        model.toggleTun(false); await settle(model)
        XCTAssertEqual(model.desiredMode, .off)
        XCTAssertEqual(model.displayStatus(at: clock.now()), .stale)
        XCTAssertEqual(MenuBarMode(model.displayStatus(at: clock.now())), .attention)
        XCTAssertNil(model.error)
        await api.recover("/api/status"); await model.pollOnce()
        XCTAssertEqual(model.displayStatus(at: clock.now()), .stopped)
        _ = await model.shutdown()
    }

}
