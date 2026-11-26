import XCTest
import V2rayMDomain
@testable import V2rayMApplication

@MainActor private final class ModuleRuntime: NativeModuleUpdateRuntime {
    var submitted: ModuleUpdateScope?
    var cancelAfterSubmit = false
    func submit(_ scope: ModuleUpdateScope) async throws {
        submitted = scope
        if cancelAfterSubmit { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

@MainActor final class NativeModuleUpdateServiceTests: XCTestCase {
    func testCancellationBeforeSubmissionCannotStartUpdate() async {
        let runtime = ModuleRuntime()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await NativeModuleUpdateService().submit(.geo, runtime: runtime)
        }
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
