import XCTest
import Foundation
import V2rayMDomain
@testable import V2rayMApplication

@MainActor private final class RecoveryRuntime: NativeRecoveryRuntime {
    var recovery = NetworkRecovery()
    var observation = RecoveryObservation(awake: true, networkAvailable: true, desiredMode: .system,
        systemProxyEnabled: true, tunEnabled: false, tunRunning: false, coreRunning: true,
        runtimeState: "running", coreStartedAt: "old", updating: false, proxyNeedsRecovery: false)
    var calls: [String] = []
    var hook: ((String, RecoveryRuntime) async throws -> Void)?
    init(restart: Bool = true) { recovery.begin(restart: restart, now: Date(timeIntervalSince1970: 0)) }
    func step(_ name: String) async throws { calls.append(name); try await hook?(name, self) }
    func refresh(generation: Int, includeOperations: Bool) async throws { try await step(includeOperations ? "capture" : "refresh") }
    func reconcileMode() async throws { try await step("reconcile") }
    func checkBeforeConnecting() async throws { try await step("preflight") }
    func startOrRestartCore(restart: Bool) async throws { try await step(restart ? "restart" : "start") }
    func synchronizeProxyPort() async throws { try await step("rebind") }
}

@MainActor final class NetworkRecoveryServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10)

    func testUpdateStartingDuringPreflightDefersRestart() async throws {
        let runtime = RecoveryRuntime()
        runtime.hook = { step, runtime in
            if step == "preflight" { runtime.observation.updating = true }
        }
        let result = try await NetworkRecoveryService().attempt(runtime, now: now)
        XCTAssertEqual(result, .waiting)
        XCTAssertEqual(runtime.calls, ["capture", "preflight"])
        XCTAssertTrue(runtime.recovery.active)
    }

    func testNetworkGenerationChangeDuringPreflightPreventsRestart() async throws {
        let runtime = RecoveryRuntime()
        runtime.hook = { step, runtime in
            if step == "preflight" { runtime.recovery.begin(restart: true, now: self.now) }
        }
        let result = try await NetworkRecoveryService().attempt(runtime, now: now)
        XCTAssertEqual(result, .waiting)
        XCTAssertEqual(runtime.calls, ["capture", "preflight"])
        XCTAssertTrue(runtime.recovery.active); XCTAssertTrue(runtime.recovery.needsRestart)
    }

    func testAcceptedRestartWithLostAcknowledgementIsVerifiedWithoutResubmission() async throws {
        let runtime = RecoveryRuntime()
        runtime.hook = { step, runtime in
            if step == "restart" { runtime.observation.coreStartedAt = "new"; throw URLError(.timedOut) }
        }
        do { _ = try await NetworkRecoveryService().attempt(runtime, now: now); XCTFail("Expected lost response") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let result = try await NetworkRecoveryService().attempt(runtime, now: now)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(runtime.calls.filter { $0 == "restart" }.count, 1)
        XCTAssertFalse(runtime.recovery.active)
    }

    func testReattachingSystemPreferenceCannotSatisfyPhysicalRestart() async throws {
        let runtime = RecoveryRuntime()
        runtime.observation.systemProxyEnabled = false
        runtime.hook = { step, runtime in
            if step == "reconcile" { runtime.observation.systemProxyEnabled = true }
        }
        let result = try await NetworkRecoveryService().attempt(runtime, now: now)
        XCTAssertEqual(result, .waiting)
        XCTAssertEqual(runtime.calls, ["capture", "reconcile", "refresh"])
        XCTAssertTrue(runtime.recovery.needsRestart)
    }

    func testSameSecondReplacementIsVerifiedBySessionIDAfterReplyLoss() async throws {
        let runtime = RecoveryRuntime()
        runtime.observation.coreSessionID = UUID()
        runtime.hook = { step, runtime in
            if step == "restart" {
                runtime.observation.coreSessionID = UUID()
                throw URLError(.timedOut)
            }
        }
        do { _ = try await NetworkRecoveryService().attempt(runtime, now: now); XCTFail("Expected lost response") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let result = try await NetworkRecoveryService().attempt(runtime, now: now)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(runtime.calls.filter { $0 == "restart" }.count, 1)
    }

    func testRecoveryRechecksLostTunnelBeforeMutating() async throws {
        for stillInactive in [true, false] {
            let runtime = RecoveryRuntime(restart: false)
            runtime.observation.desiredMode = .tun
            runtime.observation.systemProxyEnabled = false
            runtime.observation.tunEnabled = true
            runtime.observation.coreSessionID = UUID()
            runtime.observation.inactiveTunSessionID = runtime.observation.coreSessionID
            runtime.hook = { step, runtime in
                if step == "restart" || (step == "capture" && !stillInactive) {
                    runtime.observation.inactiveTunSessionID = nil
                    runtime.observation.tunRunning = true
                }
            }
            let result = try await NetworkRecoveryService().attempt(runtime, now: now)
            XCTAssertEqual(result, .completed)
            XCTAssertEqual(runtime.calls.filter { $0 == "restart" }.count, stillInactive ? 1 : 0)
        }
    }

    func testUpdateOrUnresolvedProxyRecoveryBlocksMutation() async throws {
        let updating = RecoveryRuntime(); updating.observation.updating = true
        let updateResult = try await NetworkRecoveryService().attempt(updating, now: now)
        XCTAssertEqual(updateResult, .waiting); XCTAssertEqual(updating.calls, ["capture"])
        let recovery = RecoveryRuntime(); recovery.observation.systemProxyEnabled = false
        recovery.observation.proxyNeedsRecovery = true
        let recoveryResult = try await NetworkRecoveryService().attempt(recovery, now: now)
        XCTAssertEqual(recoveryResult, .proxyRecoveryRequired); XCTAssertEqual(recovery.calls, ["capture"])
    }

    func testGenerationChangeDuringRebindCannotCompleteNewRecovery() async throws {
        let runtime = RecoveryRuntime(restart: false)
        runtime.hook = { step, runtime in
            if step == "rebind" { runtime.recovery.begin(restart: true, now: self.now) }
        }
        let result = try await NetworkRecoveryService().attempt(runtime, now: now)
        XCTAssertEqual(result, .waiting)
        XCTAssertTrue(runtime.recovery.active); XCTAssertTrue(runtime.recovery.needsRestart)
    }

    func testCancellationAfterUncooperativeRefreshNeverMutatesNetwork() async {
        let runtime = RecoveryRuntime()
        runtime.hook = { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        let attempt = Task { try await NetworkRecoveryService().attempt(runtime, now: now) }
        do { _ = try await attempt.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(runtime.calls, ["capture"])
    }
}
