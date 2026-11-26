import XCTest
import Foundation
import Combine
import SwiftUI
import AppKit
import V2rayMKit
@testable import V2rayM

private actor RuntimeFixtureAPI: NativeAPI {
    var requestCounts: [String: Int] = [:]
    var logBatch: [[String: Any]] = []
    var sampleProfiles = false
    var selectedID = "fixture"
    func restartFixture(at date: String) { startedAt = date }
    func selectFixture(_ id: String) { selectedID = id; sampleProfiles = true }
    func setLogHosts(_ values: [String]) {
        logBatch = values.enumerated().map { index, host in
            ["timestamp": index == 0 ? "2026-11-24T00:00:00Z" : "2026-11-25T00:00:00Z", "source": "core",
             "sequence": index + 1, "message": "from app accepted tcp:" + host + ":443 [socks >> proxy]"]
        }
    }
    func count(_ path: String) -> Int { requestCounts[path] ?? 0 }
    var running = false
    var faulted = false
    var failNextStart = false
    var reuseRunningCore = false
    var proxyPort = 10808
    var statusReads = 0
    var stopErrors = [Error]()
    var stopCalls = 0
    var failTunRead = false
    var tunEnabled = false
    var failures = Set<String>()
    var holdNextRoutes = false
    var routesHeld: CheckedContinuation<Void, Never>?
    func holdRoutes() { holdNextRoutes = true }
    func routesAreHeld() -> Bool { routesHeld != nil }
    func releaseRoutes() { routesHeld?.resume(); routesHeld = nil }
    var starts = 0
    var restarts = 0
    var startedAt = "2026-10-24T10:00:00Z"
    var loseRestartResponse = false
    var tasks: [String] = []
    var updatePhase: String?
    func setUpdatePhase(_ phase: String) {
        updatePhase = phase
        tasks = phase == "downloading" ? ["geo-update"] : []
    }
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
    func failStops(with errors: [Error]) { stopErrors = errors }
    func failTunObservation() { failTunRead = true }
    func fail(_ path: String) { failures.insert(path) }
    func recover(_ path: String) { failures.remove(path) }
    func faultCore() { running = false; faulted = true }
    func failStartOnce() { failNextStart = true }
    func reuseLiveCoreOnStart() { reuseRunningCore = true }
    func changeProxyPort(_ port: Int) { proxyPort = port }
    func setTasks(_ values: [String]) { tasks = values }
    func holdStatus() { holdNextStatus = true }
    func statusIsHeld() -> Bool { held != nil }
    func releaseStatus() { held?.resume(returning: heldData!); held = nil; heldData = nil }
    func loseNextRestartResponse() { loseRestartResponse = true }
    func encodedResponse(_ path: String, method: String, body: Data?) async throws -> Data {
        requestCounts[path, default: 0] += 1
        if path == "/api/settings/routing-profiles", holdNextRoutes {
            holdNextRoutes = false
            await withCheckedContinuation { routesHeld = $0 }
        }
        if failures.contains(path) { throw ClientFailure("fixture_observation_failed") }
        var result: Any = [:]
        switch path {
        case "/api/status":
            statusReads += 1
            result = ["coreRunning": running, "xrayAvailable": true, "runtimeState": running ? "running" : faulted ? "faulted" : "stopped",
                      "currentProfileId": selectedID, "runningProfileId": "fixture", "runningProxyPort": proxyPort,
                      "coreStartedAt": startedAt] as [String: Any]
        case "/api/profiles?subscriptionId=&includeStatistics=false":
            result = sampleProfiles ? ["first", "second"].map { id -> [String: Any] in
                ["indexId": id, "remarks": id, "protocol": "vless", "address": id + ".invalid", "port": 443,
                 "network": "raw", "coreType": "xray", "delay": 0, "isCurrent": false, "canTest": true]
            } : []
        case "/api/profiles/observations":
            result = sampleProfiles ? [["indexId": "first", "delay": 10, "totalUp": 100, "totalDown": 50] as [String: Any]] : []
        case "/api/core-updates/progress":
            result = updatePhase.map { [["coreType": "GeoFiles", "phase": $0, "isComplete": $0 != "downloading", "success": $0 == "completed", "batch": false] as [String: Any]] } ?? []
        case "/api/settings/routing-profiles": result = method == "POST" ? ["routingId": "created-id"] : []
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
        case "/api/core/start": try await startTunCore()
        case "/api/core/stop": try stopProxyCore()
        default:
            if path.hasPrefix("/api/logs/tail") {
                let firstRead = path.hasPrefix("/api/logs/tail?after=0&")
                result = ["items": firstRead ? logBatch : [], "latestSequence": logBatch.count, "generation": 0] as [String: Any]
            }
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
            "runtimeState": running ? "running" : faulted ? "faulted" : "stopped", "privilegedCoreProcessIds": tunEnabled && running ? [42] : []]
    }
    func setTunEnabled(_ enabled: Bool) { tunEnabled = enabled }
    func startTunCore() async throws {
        if failNextStart { failNextStart = false; throw ClientFailure("core_start_failed") }
        if running && reuseRunningCore { return }
        starts += 1; running = true; startedAt = "start-\(starts)"
        if holdNextStart {
            holdNextStart = false
            await withCheckedContinuation { startHeld = $0 }
        }
    }
    func stopProxyCore() throws {
        stopCalls += 1
        if !stopErrors.isEmpty { throw stopErrors.removeFirst() }
        running = false; faulted = false
    }
    func proxyConnection() -> ProxyConnection { ProxyConnection(running: running, port: proxyPort) }
}
private actor RuntimeFixtureBackend: NativeBackend {
    let api: RuntimeFixtureAPI
    var isRunning = true
    var holdStart = false
    var startHeld: CheckedContinuation<Void, Never>?
    var stops = 0
    func suspendStart() { holdStart = true }
    func startIsHeld() -> Bool { startHeld != nil }
    func releaseStart() { startHeld?.resume(); startHeld = nil }
    init(_ api: RuntimeFixtureAPI) { self.api = api }
    func startClient() async -> any NativeAPI {
        if holdStart { await withCheckedContinuation { startHeld = $0 } }
        isRunning = true
        return api
    }
    func stop() { stops += 1; isRunning = false }
}
private actor RuntimeFixtureProxy: NativeProxy {
    var isEnabled = false
    var needsRecovery = false
    var restores = 0
    var boundPort: Int?
    func enableProxy(endpoints: ProxyEndpoints) { isEnabled = true; boundPort = endpoints.preferredPort }
    func restoreProxy() { restores += 1; isEnabled = false }
    func restore() -> Bool { restores += 1; isEnabled = false; return false }
    func rebind(endpoints: ProxyEndpoints) throws { if !isEnabled { throw ClientFailure("proxy_recovery") }; boundPort = endpoints.preferredPort }
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
    var resume: (() -> Void)?
    func observe(sleep: @escaping @MainActor (Bool) -> Void, change: @escaping @MainActor (Bool) -> Void,
                 resume: @escaping @MainActor () -> Void) {
        self.sleep = sleep; self.change = change; self.resume = resume
    }
}

private actor HeldConnectionBatch: RecentConnectionParsing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var first = true
    var held: Bool { continuation != nil }
    func recent(_ entries: [LogEntry], since start: Date) async -> [GlobeConnection] {
        if first {
            first = false
            await withCheckedContinuation { continuation = $0 }
        }
        return GlobeConnection.recent(entries, previous: [], since: start)
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class AppModelOrchestrationTests: XCTestCase {
    func testNativeWindowModelImportsSelectsEditsAndReopens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func model() -> AppModel {
            AppModel(backend: NativeRuntimeHost(dataDirectory: directory, mayContactHelper: false, automaticMaintenance: false),
                     proxy: RuntimeFixtureProxy(), clock: RuntimeFixtureClock(), network: RuntimeFixtureNetwork(),
                     dataDirectory: directory, checkTunnel: {})
        }
        let first = model()
        await first.connect()
        XCTAssertTrue(first.ready)
        try await first.importNodes("socks://user:p%3Ass@127.0.0.1:10891#One\nvless://local-id@127.0.0.1:10892?type=xhttp&path=%2Ffixture#Two")
        await first.waitForObservations()
        XCTAssertEqual(first.profiles.map(\.remarks), ["One", "Two"])
        let selected = try XCTUnwrap(first.profiles.first)
        first.select(selected)
        await settle(first)
        XCTAssertEqual(first.status?.currentProfileId, selected.id)
        XCTAssertEqual(first.status?.coreRunning, false)
        let original = try await first.profileDocument(id: selected.id)
        XCTAssertEqual(original["password"].text, "p:ss")
        var edited = original
        edited["remarks"] = .string("Renamed")
        let committed = try await first.saveProfile(id: selected.id, original: original, edited: edited)
        XCTAssertEqual(committed, edited)
        var stale = original
        stale["remarks"] = .string("Outdated")
        do {
            try await first.saveProfile(id: selected.id, original: original, edited: stale)
            XCTFail("A stale editor must not overwrite the committed edit")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_edit_conflict") }
        let closed = await first.shutdown()
        XCTAssertTrue(closed)
        let reopened = model()
        await reopened.connect()
        await reopened.waitForObservations()
        XCTAssertEqual(reopened.status?.currentProfileId, selected.id)
        XCTAssertEqual(reopened.profiles.first?.remarks, "Renamed")
        let persisted = try await reopened.profileDocument(id: selected.id)
        XCTAssertEqual(persisted, edited)
        let finished = await reopened.shutdown()
        XCTAssertTrue(finished)
    }

    func testManualGeoDownloadKeepsRuntimeAndFinishesEvenIfStatusReadFails() async {
        let (model, api, _, _, clock, _) = await fixture()
        await api.setUpdatePhase("downloading")
        model.updateModules(.geo)
        await model.waitForOperation()
        await model.waitForObservations()
        let startReads = await api.count("/api/status")
        clock.advance(3)
        await model.pollOnce()
        let endReads = await api.count("/api/status")
        XCTAssertGreaterThan(endReads, startReads, "Ordinary runtime polling must continue during file transfer")
        XCTAssertEqual(model.lastStatusRefresh, clock.now())
        await api.fail("/api/core-updates/progress")
        clock.advance(3)
        await model.pollOnce()
        XCTAssertEqual(model.lastStatusRefresh, clock.now())
        XCTAssertNotNil(model.moduleUpdateError)
        XCTAssertTrue(model.moduleUpdateActive)
        await api.recover("/api/core-updates/progress")
        await api.fail("/api/status")
        await model.pollOnce()
        XCTAssertTrue(model.moduleUpdateActive)
        XCTAssertNil(model.moduleUpdateError, "A runtime status failure is not a GeoData observation failure")
        await api.setUpdatePhase("completed")
        await model.pollOnce()
        XCTAssertFalse(model.moduleUpdateActive, "A failed status read must not conceal a terminal update")
        _ = await model.shutdown()
    }

    func testAutomaticGeoUpdateTracksBackendTaskAndPreventsDuplicateSubmission() async {
        let (model, api, _, _, clock, _) = await fixture()
        await api.setUpdatePhase("downloading")
        clock.advance(3)
        await model.pollOnce()
        await model.waitForObservations()
        XCTAssertTrue(model.moduleUpdateActive)
        model.updateModules(.geo)
        await model.waitForOperation()
        let submissions = await api.count("/api/core/geo/update?scope=geo")
        XCTAssertEqual(submissions, 0, "The scheduled job should own the update UI")
        await api.setUpdatePhase("completed")
        await model.pollOnce()
        XCTAssertFalse(model.moduleUpdateActive)
        _ = await model.shutdown()
    }

    func testIndividualGeoUpdateSubmitsWithoutChangingUpdatePreferences() async {
        let (model, api, _, _, _, _) = await fixture()
        XCTAssertEqual(model.status?.coreRunning, false)
        model.updateModules(.geo)
        await model.waitForOperation()
        let writes = await api.count("/api/core-updates/settings")
        let requests = await api.count("/api/core/geo/update?scope=geo")
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(requests, 1)
        _ = await model.shutdown()
    }

    func testAcknowledgedCreateReturnsIdentityDespiteFailedStatusRefresh() async throws {
        let (model, api, _, _, _, _) = await fixture()
        await api.fail("/api/status")
        let response = try await model.settingsWrite("/api/settings/routing-profiles", method: "POST", body: .object([:]))
        XCTAssertEqual(response["routingId"].text, "created-id")
        XCTAssertNotNil(model.observationErrors["runtime"])
        _ = await model.shutdown()
    }

    func testMetadataIsNotReloadedAtTelemetryFrequencyButCommandsForceRefresh() async throws {
        let (model, api, _, _, clock, _) = await fixture()
        let path = "/api/profiles?subscriptionId=&includeStatistics=false"
        let initial = await api.count(path)
        let readings = await api.count("/api/profiles/observations")
        clock.advance(6)
        try await model.refresh(forceMetadata: false)
        await model.waitForObservations()
        let metadata = await api.count(path)
        let observations = await api.count("/api/profiles/observations")
        XCTAssertEqual(metadata, initial)
        XCTAssertEqual(observations, readings + 1)
        try await model.refresh()
        await model.waitForObservations()
        let refreshed = await api.count(path)
        XCTAssertEqual(refreshed, initial + 1)
        _ = await model.shutdown()
    }
    func testParsedLogBatchDoesNotAdvanceCursorAcrossSessionChange() async throws {
        let api = RuntimeFixtureAPI(), held = HeldConnectionBatch()
        let model = AppModel(backend: RuntimeFixtureBackend(api), proxy: RuntimeFixtureProxy(),
                             clock: RuntimeFixtureClock(), network: RuntimeFixtureNetwork(),
                             connectionParser: held, checkTunnel: {})
        await api.setLogHosts(["old.invalid", "first.invalid", "second.invalid", "first.invalid"])
        await model.connect()
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await held.held), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let suspended = await held.held
        XCTAssertTrue(suspended)
        await api.restartFixture(at: "2026-11-25T00:00:00Z")
        model.status?.coreStartedAt = "2026-11-25T00:00:00Z"
        await held.release()
        await model.waitForObservations()
        XCTAssertTrue(model.logs.isEmpty)
        XCTAssertTrue(model.dashboard.connections.isEmpty)
        try await model.refresh()
        await model.waitForObservations()
        let firstReads = await api.count("/api/logs/tail?after=0&limit=10000")
        XCTAssertEqual(firstReads, 2)
        XCTAssertEqual(model.logs.map(\.message), ["old.invalid", "first.invalid", "second.invalid", "first.invalid"].map { "from app accepted tcp:" + $0 + ":443 [socks >> proxy]" })
        XCTAssertEqual(model.dashboard.connections.map(\.host), ["first.invalid", "second.invalid"])
        _ = await model.shutdown()
    }

    func testUnchangedObservationsAllowSelectionChangesButSkipIdlePublications() async throws {
        let (model, api, _, _, clock, _) = await fixture()
        await api.selectFixture("first")
        try await model.refresh()
        await model.waitForObservations()
        XCTAssertEqual(model.profiles.filter(\.isCurrent).map(\.id), ["first"])
        XCTAssertEqual(model.profiles.first?.delay, 10)
        var publications = 0
        let subscription = model.$profiles.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        clock.advance(6)
        try await model.refresh(forceMetadata: false)
        await model.waitForObservations()
        XCTAssertEqual(publications, 0)
        await api.selectFixture("second")
        clock.advance(6)
        try await model.refresh(forceMetadata: false)
        await model.waitForObservations()
        XCTAssertEqual(model.profiles.filter(\.isCurrent).map(\.id), ["second"])
        XCTAssertEqual(publications, 1)
        _ = await model.shutdown()
    }

    func testSettingsHomeRequestPreservesDirtyDraftAndReturnsToHome() async throws {
        let (model, _, _, _, _, _) = await fixture()
        var home = 0, overview = 0
        func page(_ request: Int) -> some View {
            SettingsEditor(pane: .routing, homeRequest: request, goHome: { home += 1 }, close: { overview += 1 })
                .environmentObject(model).frame(width: 860, height: 580)
        }
        let host = NSHostingView(rootView: page(0))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func buttons(in view: NSView) -> [NSButton] {
            ([view as? NSButton].compactMap { $0 }) + view.subviews.flatMap(buttons)
        }
        func respond(_ label: String) async throws {
            await waitUntil { window.attachedSheet?.contentView.map { buttons(in: $0).contains { $0.title == label } } ?? false }
            let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
            let button = try XCTUnwrap(buttons(in: sheet).first { $0.title == label })
            button.performClick(nil)
            await waitUntil { window.attachedSheet == nil }
        }
        // The fixture has no routes. Loading the editor creates an unsaved first draft.
        try await Task.sleep(for: .milliseconds(250))
        host.rootView = page(1)
        try await respond("继续编辑")
        XCTAssertEqual(home, 0)
        host.rootView = page(2)
        try await respond("放弃修改")
        XCTAssertEqual(home, 1)
        XCTAssertEqual(overview, 0)
    }

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
    func testShutdownDrainsInitialConnectionAndNeverPublishesLateReadiness() async {
        let backend = RuntimeFixtureBackend(RuntimeFixtureAPI())
        await backend.suspendStart()
        let model = AppModel(backend: backend, proxy: RuntimeFixtureProxy(), clock: RuntimeFixtureClock(),
                             network: RuntimeFixtureNetwork(), checkTunnel: {})
        let start = Task { await model.connect() }
        await waitUntil { await backend.startIsHeld() }
        let exit = Task { await model.shutdown() }
        await Task.yield()
        let earlyStops = await backend.stops
        XCTAssertEqual(earlyStops, 0)
        await backend.releaseStart()
        await start.value
        let completed = await exit.value
        XCTAssertTrue(completed); XCTAssertFalse(model.ready)
        let running = await backend.isRunning
        XCTAssertFalse(running)
    }
    func testShutdownDrainsSettingsCommandPostWriteObservation() async {
        let (model, api, backend, _, _, _) = await fixture()
        await api.holdStatus()
        let write = Task { try await model.settingsWrite("/fixture/settings") }
        await waitUntil { await api.statusIsHeld() }
        let exit = Task { await model.shutdown() }
        await Task.yield()
        let earlyStops = await backend.stops
        XCTAssertEqual(earlyStops, 0)
        await api.releaseStatus()
        do { try await write.value } catch { XCTFail("Unexpected settings failure: \(error)") }
        let completed = await exit.value
        XCTAssertTrue(completed)
        let running = await backend.isRunning
        XCTAssertFalse(running)
    }
    func testEmptyLogPollDoesNotRepublishUnchangedLogDocument() async {
        let (model, _, _, _, _, _) = await fixture()
        var publications = 0
        let observation = model.logState.$entries.dropFirst().sink { _ in publications += 1 }
        _ = try? await model.refresh(); await model.waitForObservations()
        XCTAssertNil(model.observationErrors["logs"])
        XCTAssertEqual(publications, 0)
        observation.cancel()
        _ = await model.shutdown()
    }
    func testShutdownDrainsCanceledMetadataBeforeStoppingOwnedBackend() async {
        let (model, api, backend, _, _, _) = await fixture()
        await api.holdRoutes()
        _ = try? await model.refresh()
        await waitUntil { await api.routesAreHeld() }
        let shutdown = Task { await model.shutdown() }
        await Task.yield()
        let stillRunning = await backend.isRunning
        XCTAssertTrue(stillRunning)
        await api.releaseRoutes()
        let stopped = await shutdown.value
        XCTAssertTrue(stopped)
        let running = await backend.isRunning
        XCTAssertFalse(running)
        XCTAssertNil(model.observationErrors["routes"])
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
    func testLostTunLeaseRecoversWithoutWakeNotificationAndOffCancelsRetry() async {
        let (model, api, _, _, clock, _) = await fixture()
        model.toggleTun(true); await settle(model)
        await api.faultCore()
        await model.pollOnce()
        XCTAssertTrue(model.networkRecovery.active)
        XCTAssertEqual(model.desiredMode, .tun)
        clock.advance(4)
        await model.pollOnce()
        XCTAssertFalse(model.networkRecovery.active)
        XCTAssertTrue(model.tun?.isRunning == true)
        XCTAssertNil(model.error)

        await api.faultCore(); await model.pollOnce()
        XCTAssertTrue(model.networkRecovery.active)
        model.toggleTun(false); await settle(model)
        let starts = await api.starts
        clock.advance(31); await model.pollOnce()
        let after = await api.starts
        XCTAssertEqual(after, starts)
        XCTAssertEqual(model.desiredMode, .off)
        XCTAssertFalse(model.networkRecovery.active)
        XCTAssertNil(model.error)
        _ = await model.shutdown()
    }

    func testWakeRecoveryRetriesWhileHelperCleanupIsUnconfirmed() async {
        let (model, api, _, _, clock, network) = await fixture()
        model.toggleTun(true); await settle(model)
        network.sleep?(true); network.sleep?(false); clock.advance(4)
        await api.fail("/api/core/restart")
        await model.pollOnce()
        XCTAssertTrue(model.networkRecovery.active)
        XCTAssertNil(model.error)
        let before = await api.restarts
        await model.pollOnce()
        let duringBackoff = await api.restarts
        XCTAssertEqual(before, duringBackoff)
        await api.recover("/api/core/restart")
        clock.advance(31); await model.pollOnce()
        XCTAssertFalse(model.networkRecovery.active)
        XCTAssertTrue(model.tun?.isRunning == true)
        XCTAssertEqual(model.desiredMode, .tun)
        XCTAssertNil(model.error)
        _ = await model.shutdown()
    }
    func testFailedSwitchFromFaultedTunReconcilesTheOriginalIntent() async {
        let (model, api, _, _, clock, _) = await fixture()
        model.toggleTun(true); await settle(model)
        await api.faultCore(); _ = try? await model.refresh(); await model.waitForObservations()
        await api.failStartOnce()
        model.toggleProxy(true); await settle(model)
        XCTAssertEqual(model.desiredMode, .tun)
        let enabledAfterRollback = await api.tunEnabled
        XCTAssertFalse(enabledAfterRollback, "rollback selected off because no core was running")
        await model.pollOnce(); clock.advance(4); await model.pollOnce()
        XCTAssertFalse(model.networkRecovery.active)
        XCTAssertTrue(model.tun?.isRunning == true)
        XCTAssertFalse(model.systemProxyEnabled)
        _ = await model.shutdown()
    }
    func testDisplayResumeChecksHealthyModesWithoutRestarting() async {
        for mode in [ProxyMode.system, .tun] {
            let (model, api, _, _, clock, network) = await fixture()
            if mode == .system { model.toggleProxy(true) } else { model.toggleTun(true) }
            await settle(model)
            network.resume?()
            let generation = model.networkRecovery.generation
            network.resume?(); network.resume?()
            XCTAssertEqual(model.networkRecovery.generation, generation)
            clock.advance(4); await model.pollOnce()
            let restarts = await api.restarts
            XCTAssertEqual(restarts, 0)
            XCTAssertFalse(model.networkRecovery.active)
            XCTAssertEqual(model.displayStatus(at: clock.now()), mode == .system ? .system : .tun)
            _ = await model.shutdown()
        }
    }
    func testDisplayResumeRecoversFaultAndReleasesMissedSystemWakeGate() async {
        for missedSystemWake in [false, true] {
            let (model, api, _, _, clock, network) = await fixture()
            model.toggleTun(true); await settle(model)
            if missedSystemWake { network.sleep?(true) }
            await api.faultCore()
            network.resume?(); clock.advance(4); await model.pollOnce()
            XCTAssertFalse(model.networkRecovery.active)
            XCTAssertTrue(model.tun?.isRunning == true)
            let beforeDuplicate = await api.restarts
            if missedSystemWake { network.sleep?(false) }
            network.resume?(); clock.advance(4); await model.pollOnce()
            let afterDuplicate = await api.restarts
            XCTAssertEqual(beforeDuplicate, afterDuplicate)
            _ = await model.shutdown()
        }
    }
    func testResumeSignalsDoNotInvalidateAnInFlightWakeRestart() async {
        let (model, api, _, _, clock, network) = await fixture()
        model.toggleTun(true); await settle(model)
        network.sleep?(true); network.sleep?(false); clock.advance(4)
        await api.holdRestart()
        let recovery = Task { await model.pollOnce() }
        await waitUntil { await api.restartIsHeld() }
        let generation = model.networkRecovery.generation
        network.resume?(); network.sleep?(false); network.resume?()
        XCTAssertEqual(model.networkRecovery.generation, generation)
        await api.releaseRestart(); await recovery.value
        clock.advance(31); await model.pollOnce()
        let restarts = await api.restarts
        XCTAssertEqual(restarts, 1); XCTAssertFalse(model.networkRecovery.active)
        _ = await model.shutdown()
    }
    func testLaterSystemWakeStillRestartsWhenWillSleepWasNotDelivered() async {
        let (model, api, _, _, clock, network) = await fixture()
        model.toggleTun(true); await settle(model)
        network.sleep?(false); clock.advance(4); await model.pollOnce()
        let first = await api.restarts
        XCTAssertEqual(first, 1)
        clock.advance(60)
        network.sleep?(false); clock.advance(4); await model.pollOnce()
        let second = await api.restarts
        XCTAssertEqual(second, 2)
        XCTAssertFalse(model.networkRecovery.active)
        _ = await model.shutdown()
    }
    func testOffDuringModeReconciliationStopsTheLateStartedCore() async {
        let (model, api, _, _, clock, _) = await fixture()
        model.toggleTun(true); await settle(model)
        await api.faultCore(); _ = try? await model.refresh(); await model.waitForObservations()
        await api.failStartOnce(); model.toggleProxy(true); await settle(model)
        await model.pollOnce(); clock.advance(4)
        await api.holdStart()
        let recovery = Task { await model.pollOnce() }
        await waitUntil { await api.startIsHeld() }
        model.toggleTun(false)
        XCTAssertEqual(model.desiredMode, .off)
        await api.releaseStart(); await recovery.value; await settle(model)
        let running = await api.running, tunEnabled = await api.tunEnabled
        XCTAssertFalse(running); XCTAssertFalse(tunEnabled)
        XCTAssertFalse(model.networkRecovery.active)
        clock.advance(31); await model.pollOnce()
        let stillRunning = await api.running
        XCTAssertFalse(stillRunning)
        _ = await model.shutdown()
    }
    func testPhysicalNetworkChangeDuringRestartRequiresNewGenerationRecovery() async {
        let (model, api, _, _, clock, network) = await fixture()
        network.change?(true)
        model.toggleTun(true); await settle(model)
        network.sleep?(true); network.sleep?(false); clock.advance(4)
        await api.holdRestart()
        let recovery = Task { await model.pollOnce() }
        await waitUntil { await api.restartIsHeld() }
        network.change?(false); network.change?(true); network.resume?()
        await api.releaseRestart(); await recovery.value
        XCTAssertTrue(model.networkRecovery.active)
        clock.advance(4); await model.pollOnce()
        let restarts = await api.restarts
        XCTAssertEqual(restarts, 2); XCTAssertFalse(model.networkRecovery.active)
        _ = await model.shutdown()
    }
    func testOfflineRecoveryKeepsLocalObservationsAndCoalescesWifiFlapping() async {
        let (model, api, _, _, clock, network) = await fixture()
        network.change?(true)
        model.toggleTun(true); await settle(model)
        network.change?(false); network.resume?()
        let before = await api.statusReads
        clock.advance(31); await model.pollOnce(); await model.waitForObservations()
        let after = await api.statusReads, offlineRestarts = await api.restarts
        XCTAssertGreaterThan(after, before); XCTAssertEqual(offlineRestarts, 0)
        for _ in 0..<4 { network.change?(true); network.change?(false) }
        network.change?(true); network.resume?()
        await model.pollOnce()
        let earlyRestarts = await api.restarts
        XCTAssertEqual(earlyRestarts, 0)
        clock.advance(4); await model.pollOnce()
        let finalRestarts = await api.restarts
        XCTAssertEqual(finalRestarts, 1); XCTAssertFalse(model.networkRecovery.active)
        _ = await model.shutdown()
    }
    func testSystemRecoveryRebindsAChangedProxyPort() async {
        let (model, api, _, proxy, clock, network) = await fixture()
        model.toggleProxy(true); await settle(model)
        network.sleep?(true); network.sleep?(false)
        await api.changeProxyPort(20808)
        clock.advance(4); await model.pollOnce()
        let port = await proxy.boundPort
        XCTAssertEqual(port, 20808); XCTAssertFalse(model.networkRecovery.active)
        XCTAssertTrue(model.systemProxyEnabled)
        _ = await model.shutdown()
    }
    func testReattachingSystemProxyDoesNotSkipRequiredWakeRestart() async {
        let (model, api, _, _, clock, network) = await fixture()
        model.toggleProxy(true); await settle(model)
        model.systemProxyEnabled = false
        await api.reuseLiveCoreOnStart()
        network.sleep?(true); network.sleep?(false); clock.advance(4)
        await model.pollOnce()
        XCTAssertTrue(model.systemProxyEnabled)
        XCTAssertTrue(model.networkRecovery.active)
        XCTAssertTrue(model.networkRecovery.needsRestart)
        await model.pollOnce()
        let restarts = await api.restarts
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(model.networkRecovery.active)
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
    func testStopContentionAndTimeoutKeepOffIntentAndNeverRestartOldMode() async {
        for mode in [ProxyMode.system, .tun] {
            let (model, api, _, proxy, clock, network) = await fixture()
            if mode == .system { model.toggleProxy(true) } else { model.toggleTun(true) }
            await settle(model)
            let starts = await api.starts
            network.sleep?(true); network.sleep?(false)
            await api.failStops(with: [ClientFailure("operation_in_progress"), URLError(.timedOut)])
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
