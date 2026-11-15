import XCTest
import V2rayMDomain
@testable import V2rayMApplication

@MainActor private final class CommandRuntime: NativeCommandRuntime {
    var calls: [String] = []
    var fresh = true
    var shouldDetachSystemProxy = true
    var retry: CommandFailureDisposition = .report
    var cleanupFails = false
    enum Failure: Error { case command, cleanup }
    func observe() -> Bool { calls.append("observe"); return fresh }
    func synchronizeProxyPort() { calls.append("rebind") }
    func reconcileFailure(_ error: Error) { calls.append("reconcile") }
    func disposition(_ error: Error, finishingDisconnect: Bool) -> CommandFailureDisposition { retry }
    func scheduleRetry(_ disposition: CommandFailureDisposition, error: Error) { calls.append("retry") }
    func restoreSystemProxy() throws { calls.append("restore"); if cleanupFails { throw Failure.cleanup } }
}

@MainActor final class NativeCommandServiceTests: XCTestCase {
    func testFailedObservationDoesNotUndoSuccessfulCommandOrRebindFromStaleData() async throws {
        let runtime = CommandRuntime(); runtime.fresh = false
        let result = try await NativeCommandService().execute({}, runtime: runtime)
        XCTAssertEqual(result, .completed); XCTAssertEqual(runtime.calls, ["observe"])
    }
    func testFailureCleanupPreservesOriginalError() async {
        let runtime = CommandRuntime(); runtime.cleanupFails = true
        do {
            _ = try await NativeCommandService().execute({ throw CommandRuntime.Failure.command }, runtime: runtime)
            XCTFail("Expected command failure")
        } catch { XCTAssertEqual(error as? CommandRuntime.Failure, .command) }
        XCTAssertEqual(runtime.calls, ["reconcile", "observe", "restore"])
    }
    func testDeferredDisconnectDoesNotObserveOrRestoreAnOldMode() async throws {
        let runtime = CommandRuntime(); runtime.retry = .retryDisconnect
        let result = try await NativeCommandService().execute({ throw CommandRuntime.Failure.command }, runtime: runtime, finishingDisconnect: true)
        XCTAssertEqual(result, .deferred); XCTAssertEqual(runtime.calls, ["reconcile", "retry"])
    }
    func testSettingsCallPropagatesFailureEvenWhenRecoveryCouldRetry() async {
        let runtime = CommandRuntime(); runtime.retry = .retryRecovery
        do {
            _ = try await NativeCommandService().execute({ throw CommandRuntime.Failure.command }, runtime: runtime, allowDeferredRetry: false)
            XCTFail("Expected settings failure")
        } catch { XCTAssertEqual(error as? CommandRuntime.Failure, .command) }
        XCTAssertFalse(runtime.calls.contains("retry"))
    }
    func testDisconnectRetryPolicyRequiresOffIntentAndTransientModeFailure() {
        XCTAssertEqual(CommandFailurePolicy.resolve(finishingDisconnect: true, desiredMode: .off, transient: true, modeSwitchFailure: true, recoveryActive: true), .retryDisconnect)
        XCTAssertEqual(CommandFailurePolicy.resolve(finishingDisconnect: true, desiredMode: .system, transient: true, modeSwitchFailure: true, recoveryActive: false), .report)
        XCTAssertEqual(CommandFailurePolicy.resolve(finishingDisconnect: true, desiredMode: .off, transient: false, modeSwitchFailure: true, recoveryActive: false), .report)
    }
}
