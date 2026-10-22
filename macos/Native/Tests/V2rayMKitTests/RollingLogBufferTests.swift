import XCTest
@testable import V2rayMKit

final class RollingLogBufferTests: XCTestCase {
    private func entry(_ sequence: Int) throws -> LogEntry {
        try JSONDecoder().decode(LogEntry.self, from: Data("{\"timestamp\":\"2026-10-21\",\"source\":\"core\",\"sequence\":\(sequence),\"message\":\"line \(sequence)\"}".utf8))
    }
    func testOverlappingAndEmptyRefreshesKeepExistingRowsAndIdentifiers() throws {
        var buffer = RollingLogBuffer()
        buffer.append(try [entry(1), entry(2)])
        let first = buffer.entries[0].id
        buffer.append([]); buffer.append(try [entry(2), entry(3)])
        XCTAssertEqual(buffer.entries.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(buffer.entries[0].id, first)
    }
    func testOnlyTheOldestRowsAreEvictedAtCapacity() throws {
        var buffer = RollingLogBuffer(maximumLines: 3)
        buffer.append(try (1...4).map(entry))
        XCTAssertEqual(buffer.entries.map(\.sequence), [2, 3, 4])
        buffer.append(try [entry(5)])
        XCTAssertEqual(buffer.entries.map(\.sequence), [3, 4, 5])
    }
}
