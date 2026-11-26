import XCTest
import Foundation
import V2rayMDomain
@testable import V2rayMApplication

@MainActor private final class PollingRuntime: NativePollingRuntime {
    var busy = false
    var canObserve: Bool { !busy }
    var connection = ConnectionCoordinator()
    var observation = RecoveryObservation(awake: true, networkAvailable: true, desiredMode: .off,
        systemProxyEnabled: true, tunEnabled: false, tunRunning: false, coreRunning: false,
        runtimeState: "stopped", coreStartedAt: nil, updating: false, proxyNeedsRecovery: false)
    var now = Date(timeIntervalSince1970: 100)
    var moduleUpdateActive = false
    var pendingDisconnect = false
    var disconnectRetryDue = true
    var operationsObservationValid = true
    var calls: [String] = []
    var invalidateOnRefresh = false
    var failRefresh = false
    var freshUpdating = false
    enum Failure: Error { case observation }
    func backendIsRunning() -> Bool { calls.append("host"); return true }
    func setBusy(_ busy: Bool) { self.busy = busy }
    func cancelRecoveryAndObservations() { connection.recovery.cancel() }
    func publishBackendExited() { calls.append("exited") }
    func restoreSystemProxy() { calls.append("restore") }
    func retryDisconnect() { calls.append("disconnect") }
    func attemptRecovery() { calls.append("recover") }
    func refresh() throws {
        calls.append("refresh")
        if invalidateOnRefresh { connection.invalidateObservations() }
        if failRefresh { throw Failure.observation }
    }
    func freshUpdateActivity() -> Bool { calls.append("updates"); return freshUpdating }
    func synchronizeProxyPort() { calls.append("rebind") }
    func beginRecovery(restart: Bool) { calls.append("begin") }
    func retryRecovery() { calls.append("retry") }
    func reportObservationFailure(_ error: Error) { calls.append("error") }
    func reportUpdateWaiting() { calls.append("waiting") }
    func isTransient(_ error: Error) -> Bool { true }
}

@MainActor final class NativePollingServiceTests: XCTestCase {
    func testObservationFailureNeverDetachesSystemProxy() async {
        let runtime = PollingRuntime(); runtime.failRefresh = true
        await NativePollingService().poll(runtime)
        XCTAssertEqual(runtime.calls, ["host", "refresh", "error"])
    }
    func testOldPollCannotDetachAfterNewUserMutation() async {
        let runtime = PollingRuntime(); runtime.invalidateOnRefresh = true
        await NativePollingService().poll(runtime)
        XCTAssertEqual(runtime.calls, ["host", "refresh"])
    }
    func testFreshUpdateActivityPreventsCleanupOfTemporarilyStoppedCore() async {
        let runtime = PollingRuntime(); runtime.freshUpdating = true
        await NativePollingService().poll(runtime)
        XCTAssertEqual(runtime.calls, ["host", "refresh", "updates"])
        XCTAssertFalse(runtime.busy)
    }
    func testPendingDisconnectDoesNotRequireNetworkObservation() async {
        let runtime = PollingRuntime(); runtime.pendingDisconnect = true; runtime.observation.networkAvailable = false
        await NativePollingService().poll(runtime)
        XCTAssertEqual(runtime.calls, ["host", "disconnect"])
    }
    func testLiveCoreLostTunnelRequiresAffirmativeEvidenceForCurrentSession() async {
        let session = UUID()
        for observed in [nil, UUID(), session] {
            let runtime = PollingRuntime()
            runtime.connection.request(.tun)
            runtime.observation = RecoveryObservation(awake: true, networkAvailable: true, desiredMode: .tun,
                systemProxyEnabled: false, tunEnabled: true, tunRunning: false, coreRunning: true,
                runtimeState: "faulted", coreStartedAt: nil, updating: false, proxyNeedsRecovery: false,
                coreSessionID: session, inactiveTunSessionID: observed)
            await NativePollingService().poll(runtime)
            XCTAssertEqual(runtime.calls.contains("begin"), observed == session)
        }
    }
    func testModuleCompletionNeedsEveryTargetAndNoOwnedUpdateInFlight() {
        XCTAssertFalse(NativeModuleUpdateCompletion.finished(starting: true, operations: [], targets: ["Xray"], terminalTargets: ["Xray"]))
        XCTAssertFalse(NativeModuleUpdateCompletion.finished(starting: false, operations: ["geo-update"], targets: ["GeoFiles"], terminalTargets: ["GeoFiles"]))
        XCTAssertFalse(NativeModuleUpdateCompletion.finished(starting: false, operations: [], targets: ["Xray", "GeoFiles"], terminalTargets: ["Xray"]))
        XCTAssertTrue(NativeModuleUpdateCompletion.finished(starting: false, operations: ["unrelated"], targets: ["Xray"], terminalTargets: ["Xray", "GeoFiles"]))
    }
}
