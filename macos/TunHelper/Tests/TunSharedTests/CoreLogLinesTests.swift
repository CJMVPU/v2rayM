import XCTest
@testable import TunShared

final class CoreLogLinesTests: XCTestCase {
    func testCoalescedRecordsAndSplitUTF8RemainSeparateCompleteLines() {
        let lines = CoreLogLines()
        let data = Data("第一行\r\nsecond\nthird".utf8)
        XCTAssertEqual(lines.append(data.prefix(2)), [])
        XCTAssertEqual(lines.append(data.dropFirst(2).dropLast(3)), ["第一行", "second"])
        XCTAssertEqual(lines.append(data.suffix(3), end: true), ["third"])
    }
    func testLongReadDoesNotDiscardEverythingAfter8192Bytes() {
        let lines = CoreLogLines()
        let entries = (0..<400).map { "entry \($0) " + String(repeating: "x", count: 40) }
        XCTAssertEqual(lines.append(Data((entries.joined(separator: "\n") + "\n").utf8)), entries)
    }
    func testOversizedRecordIsBoundedAndNextLineSurvives() {
        let lines = CoreLogLines()
        let result = lines.append(Data((String(repeating: "x", count: 100_000) + "\nnext\n").utf8))
        XCTAssertEqual(result.count, 2); XCTAssertTrue(result[0].contains("truncated")); XCTAssertEqual(result[1], "next")
    }
}
