import XCTest
import V2rayMDomain
@testable import V2rayMApplication

@MainActor private final class ModuleRuntime: NativeModuleUpdateRuntime {
    var submissions: [Bool?] = []
    var cancelAfterSubmit = false
    func submitGeoUpdate(useProxy: Bool?) async throws {
        submissions.append(useProxy)
        if cancelAfterSubmit { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

@MainActor final class NativeModuleUpdateServiceTests: XCTestCase {
    func testCancellationBeforeSubmissionCannotStartUpdate() async {
        let runtime = ModuleRuntime()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await NativeModuleUpdateService().submit(to: runtime)
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(runtime.submissions.isEmpty)
    }
    func testAcceptedUpdateIsNotReportedAsUndoneWhenCallerCancels() async throws {
        let runtime = ModuleRuntime(); runtime.cancelAfterSubmit = true
        let task = Task { try await NativeModuleUpdateService().submit(to: runtime) }
        try await task.value
        XCTAssertEqual(runtime.submissions, [nil])
    }
}
