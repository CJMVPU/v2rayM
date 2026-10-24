import XCTest
@testable import TunShared

final class BoundedCoreLogsTests: XCTestCase {
    func testCountBoundEvictsOldestAcrossCompactionAndDrainResetsState() {
        var logs = BoundedCoreLogs(maximumCount: 3, maximumBytes: 100)
        for number in 0..<10_000 { logs.append(String(number)) }
        XCTAssertEqual(logs.count, 3)
        XCTAssertEqual(logs.drain(), ["9997", "9998", "9999"])
        XCTAssertEqual(logs.bytes, 0)
        XCTAssertEqual(logs.count, 0)
        XCTAssertEqual(logs.drain(), [])
        logs.append("next")
        XCTAssertEqual(logs.drain(), ["next"])
    }
    func testByteBoundCountsUTF8AndDropsAnEntryLargerThanTheWholeBudget() {
        var logs = BoundedCoreLogs(maximumCount: 10, maximumBytes: 7)
        logs.append("abc"); logs.append("中文")
        XCTAssertEqual(logs.bytes, 6)
        XCTAssertEqual(logs.drain(), ["中文"])
        logs.append("12345678")
        XCTAssertEqual(logs.count, 0)
        XCTAssertEqual(logs.bytes, 0)
        logs.append("tail")
        XCTAssertEqual(logs.drain(), ["tail"])
    }
}
