import XCTest
@testable import V2rayMKit

final class BoundedLookupExecutorTests: XCTestCase {
    func testTimeoutDoesNotReleaseCapacityUntilBlockingWorkExits() async {
        let executor = BoundedLookupExecutor(concurrency: 1, timeout: 0.05)
        let started = expectation(description: "worker started")
        let finished = expectation(description: "worker finished")
        let gate = DispatchSemaphore(value: 0)
        let task = Task {
            await executor.run { () -> Int? in
                started.fulfill()
                gate.wait()
                finished.fulfill()
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let timedOut = await task.value
        XCTAssertNil(timedOut)
        let rejected = await executor.run { () -> Int? in
            XCTFail("Timed-out worker must still occupy its slot")
            return 1
        }
        XCTAssertNil(rejected)
        gate.signal()
        await fulfillment(of: [finished], timeout: 2)
    }
    func testCancellationReturnsWithoutWaitingForBlockingResolver() async {
        let executor = BoundedLookupExecutor(concurrency: 1, timeout: 10)
        let started = expectation(description: "worker started")
        let gate = DispatchSemaphore(value: 0)
        let task = Task {
            await executor.run { () -> Int? in
                started.fulfill(); gate.wait(); return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        gate.signal()
    }
    func testSuccessfulLookupReturnsValue() async {
        let executor = BoundedLookupExecutor()
        let result = await executor.run { 42 }
        XCTAssertEqual(result, 42)
    }
}
