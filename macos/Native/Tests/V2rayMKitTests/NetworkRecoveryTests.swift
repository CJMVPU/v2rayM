import XCTest
@testable import V2rayMKit

final class NetworkRecoveryTests: XCTestCase {
    func testHealthChecksPreserveAcceptedRestartReceiptAndGeneration() {
        var recovery = NetworkRecovery()
        recovery.begin(restart: true)
        let generation = recovery.generation
        recovery.submitted(identity: "before", generation: generation)
        recovery.begin(restart: false)
        XCTAssertEqual(recovery.generation, generation)
        XCTAssertEqual(recovery.action(desiredMode: .tun, systemProxyEnabled: false, tunEnabled: true,
            coreRunning: true, runtimeState: "running", coreIdentity: "after"), .verify)
        XCTAssertEqual(recovery.action(desiredMode: .tun, systemProxyEnabled: false, tunEnabled: true,
            coreRunning: true, runtimeState: "running", coreIdentity: nil), .restart,
            "a missing timestamp cannot prove a timed-out restart succeeded")
        recovery.begin(restart: true)
        XCTAssertEqual(recovery.action(desiredMode: .tun, systemProxyEnabled: false, tunEnabled: true,
            coreRunning: true, runtimeState: "running", coreIdentity: "after"), .restart)
    }
    func testDecisionAlignsIntentBeforeRestartAndWaitsForTransitions() {
        var recovery = NetworkRecovery(); recovery.begin(restart: true)
        XCTAssertEqual(recovery.action(desiredMode: .tun, systemProxyEnabled: false, tunEnabled: false,
            coreRunning: false, runtimeState: "stopped", coreIdentity: nil), .reconcileMode)
        XCTAssertEqual(recovery.action(desiredMode: .system, systemProxyEnabled: false, tunEnabled: false,
            coreRunning: true, runtimeState: "running", coreIdentity: "now"), .reconcileMode)
        XCTAssertEqual(recovery.action(desiredMode: .tun, systemProxyEnabled: false, tunEnabled: false,
            coreRunning: false, runtimeState: "stopping", coreIdentity: nil), .wait)
        XCTAssertEqual(recovery.action(desiredMode: .off, systemProxyEnabled: false, tunEnabled: true,
            coreRunning: false, runtimeState: "faulted", coreIdentity: nil), .wait)
    }
    func testWakeWaitsForNetworkAndDebouncesBeforeRestart() {
        let now = Date(timeIntervalSince1970: 100)
        var recovery = NetworkRecovery()
        recovery.begin(restart: true, now: now)
        XCTAssertFalse(recovery.canAttempt(awake: true, networkAvailable: true, now: now))
        XCTAssertFalse(recovery.canAttempt(awake: false, networkAvailable: true, now: now.addingTimeInterval(5)))
        XCTAssertFalse(recovery.canAttempt(awake: true, networkAvailable: false, now: now.addingTimeInterval(5)))
        XCTAssertTrue(recovery.canAttempt(awake: true, networkAvailable: true, now: now.addingTimeInterval(5)))
        XCTAssertTrue(recovery.needsRestart)
    }
    func testNewNetworkChangeCannotBeCompletedByOldRequest() {
        var recovery = NetworkRecovery()
        recovery.begin(restart: true)
        let old = recovery.generation
        recovery.begin(restart: true)
        recovery.restarted(generation: old)
        recovery.complete(generation: old)
        XCTAssertTrue(recovery.active)
        XCTAssertTrue(recovery.needsRestart)
        recovery.restarted(generation: recovery.generation)
        XCTAssertFalse(recovery.needsRestart)
        recovery.complete(generation: recovery.generation)
        XCTAssertFalse(recovery.active)
    }
    func testTimeoutOnlyChecksAndUserOffInvalidatesRecovery() {
        var recovery = NetworkRecovery()
        recovery.begin(restart: false)
        XCTAssertFalse(recovery.needsRestart)
        let generation = recovery.generation
        recovery.cancel()
        recovery.restarted(generation: generation)
        XCTAssertFalse(recovery.active)
        XCTAssertFalse(recovery.canAttempt(awake: true, networkAvailable: true))
        XCTAssertTrue(NetworkRecovery.isTransient(URLError(.timedOut)))
        XCTAssertFalse(NetworkRecovery.isTransient(ClientFailure("tun_conflict")))
        XCTAssertFalse(NetworkRecovery.isTransient(ProxyModeFailure(systemProxyEnabled: false, rollbackFailed: true,
            underlying: ClientFailure("operation_in_progress"))))
        XCTAssertFalse(NetworkRecovery.isTransient(ProxyModeFailure(systemProxyEnabled: false, rollbackFailed: false,
            underlying: ClientFailure("tun_stop_unconfirmed"))))
    }
    func testRetryBackoffAndSharedUIState() {
        let now = Date(timeIntervalSince1970: 100)
        var recovery = NetworkRecovery()
        recovery.begin(restart: true, now: now)
        for _ in 0..<10 { recovery.retry(now: now) }
        XCTAssertEqual(recovery.nextAttempt.timeIntervalSince(now), 30)
        XCTAssertFalse(recovery.canAttempt(awake: true, networkAvailable: true, now: now))
        let state = DashboardStatus.resolve(ready: true, updating: false, busy: true, recovery: false,
            state: nil, tunRunning: true, systemProxy: false, lastRefresh: nil, now: now, reconnecting: true)
        XCTAssertEqual(state, .recovering)
        XCTAssertFalse(state.active)
        XCTAssertEqual(MenuBarMode(state), .recovering)
        XCTAssertEqual(state.title, MenuBarMode(state).label)
    }
}
