import XCTest
@testable import V2rayMApplication

final class ServingProfileReplacementTests: XCTestCase {
    private actor Trace {
        var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    func testCancellationAfterLaunchRestoresPreviousSessionBeforeReturning() async {
        let trace = Trace()
        let change = Task {
            try await ServingProfileReplacement.apply(next: "candidate", disconnect: {
                await trace.record("stop")
            }, launch: { id in
                await trace.record(id)
                withUnsafeCurrentTask { $0?.cancel() }
            }, commit: { await trace.record("commit") }, restorePrevious: {
                try Task.checkCancellation()
                await trace.record("restore")
            })
        }
        do {
            _ = try await change.value
            XCTFail("The edit must still report cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let events = await trace.events
        XCTAssertEqual(events, ["stop", "candidate", "stop", "restore"])
    }

    func testRemovalCommitsWithoutStartingAnotherNode() async throws {
        let trace = Trace()
        let restarted = try await ServingProfileReplacement.apply(next: nil, disconnect: {
            await trace.record("stop")
        }, launch: { _ in XCTFail("Unexpected launch") }, commit: {
            await trace.record("commit")
        }, restorePrevious: { XCTFail("Unexpected recovery") })
        XCTAssertFalse(restarted)
        let events = await trace.events
        XCTAssertEqual(events, ["stop", "commit"])
    }
}
