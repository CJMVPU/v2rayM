import XCTest
@testable import V2rayMKit

final class ProfileObservationTests: XCTestCase {
    func testTelemetryMergeKeepsMetadataOrderAndResetsClearedTotals() throws {
        let json = #"[{"indexId":"one","remarks":"Name","protocol":"socks","address":"host","port":1080,"network":"raw","coreType":"xray","delay":9,"isCurrent":false,"canTest":true,"totalUp":42,"totalDown":100}]"#
        let metadata = try JSONDecoder().decode([Profile].self, from: Data(json.utf8))
        let readings = [ProfileObservation(indexId: "one", delay: 35, totalUp: 50, totalDown: 120),
                        ProfileObservation(indexId: "deleted", delay: 1, totalUp: 1, totalDown: 1)]
        let merged = ProfileObservation.applying(readings, to: metadata, selectedID: "one")
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].remarks, "Name")
        XCTAssertEqual(merged[0].address, "host")
        XCTAssertEqual(merged[0].delay, 35)
        XCTAssertEqual(merged[0].totalDown, 120)
        XCTAssertTrue(merged[0].isCurrent)
        let cleared = ProfileObservation.applying([], to: merged, selectedID: nil)
        XCTAssertEqual(cleared[0].totalDown, 0)
        XCTAssertFalse(cleared[0].isCurrent)
    }
}
