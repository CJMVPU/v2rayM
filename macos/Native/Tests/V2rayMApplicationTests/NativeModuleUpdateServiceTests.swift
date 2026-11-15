import XCTest
import V2rayMDomain
@testable import V2rayMApplication

@MainActor private final class ModuleRuntime: NativeModuleUpdateRuntime {
    var coreRunning = false
    var plan = NativeModuleUpdatePlan(installableTargets: ["Xray", "unknown", "Xray"], useProxy: true)
    var saved: NativeModuleUpdatePlan?
    var submitted: ModuleUpdateScope?
    var failSave = false
    var cancelAfterSave = false
    var cancelAfterSubmit = false
    enum Failure: Error { case save }
    func loadPlan() async throws -> NativeModuleUpdatePlan { plan }
    func savePreferences(_ plan: NativeModuleUpdatePlan) async throws {
        if failSave { throw Failure.save }
        saved = plan
        if cancelAfterSave { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func submit(_ scope: ModuleUpdateScope) async throws {
        submitted = scope
        if cancelAfterSubmit { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

@MainActor final class NativeModuleUpdateServiceTests: XCTestCase {
    func testPlanFiltersTargetsAndOnlyUsesProxyWithRunningCore() async throws {
        for running in [false, true] {
            let runtime = ModuleRuntime(); runtime.coreRunning = running
            try await NativeModuleUpdateService().submit(.all, runtime: runtime)
            XCTAssertEqual(runtime.saved?.targets, ["Xray", "GeoFiles"])
            XCTAssertEqual(runtime.saved?.preReleaseTargets, ["Xray"])
            XCTAssertEqual(runtime.saved?.preRelease, true)
            XCTAssertEqual(runtime.saved?.useProxy, running)
            XCTAssertEqual(runtime.submitted, .all)
        }
    }
    func testFailedPreferenceSaveCannotStartUpdate() async {
        let runtime = ModuleRuntime(); runtime.failSave = true
        do { try await NativeModuleUpdateService().submit(.xray, runtime: runtime); XCTFail("Expected save failure") }
        catch { XCTAssertTrue(error is ModuleRuntime.Failure) }
        XCTAssertNil(runtime.submitted)
    }
    func testCancellationAfterSaveCannotStartUpdate() async {
        let runtime = ModuleRuntime(); runtime.cancelAfterSave = true
        let task = Task { try await NativeModuleUpdateService().submit(.geo, runtime: runtime) }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(runtime.submitted)
    }
    func testAcceptedUpdateIsNotReportedAsUndoneWhenCallerCancels() async throws {
        let runtime = ModuleRuntime(); runtime.cancelAfterSubmit = true
        let task = Task { try await NativeModuleUpdateService().submit(.geo, runtime: runtime) }
        try await task.value
        XCTAssertEqual(runtime.submitted, .geo)
    }
}
