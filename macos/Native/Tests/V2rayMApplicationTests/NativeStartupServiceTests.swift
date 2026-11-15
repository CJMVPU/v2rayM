import XCTest
import V2rayMDomain
@testable import V2rayMApplication

@MainActor private final class StartupRuntime: NativeStartupRuntime {
    var calls: [String] = []
    var enabled = true
    var running = false
    var systemProxyEnabled = false
    var intent: ProxyMode?
    var failRefresh = false
    enum Failure: Error { case refresh }
    func inspectProxyRecovery() { calls.append("inspect") }
    func startBackend() { calls.append("start") }
    func readTunState() -> TunModeState {
        calls.append("read")
        return TunModeState(helperAvailable: true, enabled: enabled, runtimeState: running ? "running" : "stopped", ownedProcessIDs: running ? [42] : [])
    }
    func disableIdleTunIntent() { calls.append("disable"); enabled = false }
    func refresh() throws { calls.append("refresh"); if failRefresh { throw Failure.refresh } }
    func restoreIntent(_ mode: ProxyMode) { intent = mode; calls.append("intent") }
    func connected() { calls.append("connected") }
    func stopAfterFailure() { calls.append("cleanup") }
}

@MainActor final class NativeStartupServiceTests: XCTestCase {
    func testPersistedIdleTunIsDisabledBeforePublishingReady() async throws {
        let runtime = StartupRuntime()
        try await NativeStartupService().connect(runtime)
        XCTAssertEqual(runtime.calls, ["inspect", "start", "read", "disable", "read", "refresh", "intent", "connected"])
        XCTAssertEqual(runtime.intent, .off)
    }
    func testRunningTunRestoresIntentWithoutReconfiguration() async throws {
        let runtime = StartupRuntime(); runtime.running = true
        try await NativeStartupService().connect(runtime)
        XCTAssertFalse(runtime.calls.contains("disable")); XCTAssertEqual(runtime.intent, .tun)
    }
    func testFailedInitialObservationCleansBackendAndNeverPublishesReady() async {
        let runtime = StartupRuntime(); runtime.failRefresh = true
        do { try await NativeStartupService().connect(runtime); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error is StartupRuntime.Failure) }
        XCTAssertEqual(runtime.calls.last, "cleanup")
        XCTAssertFalse(runtime.calls.contains("connected")); XCTAssertNil(runtime.intent)
    }
}
