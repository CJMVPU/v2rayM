import XCTest
@testable import V2rayMKit

final class SettingsDocumentTests: XCTestCase {
    func testEditingKnownFieldPreservesUnknownOptionsAndNullValues() throws {
        let original = try SettingsValue.parse(#"{"inbound":{"localPort":10808,"udpEnabled":true},"core":{"mux4SboxPadding":null,"futureOption":[1,"text",false]},"domainStrategy4Singbox":"ipv4_only"}"#)
        var edited = original
        edited["inbound"]["localPort"] = .number(10809)
        let decoded = try SettingsValue.parse(edited.json())
        XCTAssertEqual(decoded["core"], original["core"])
        XCTAssertEqual(decoded["domainStrategy4Singbox"], original["domainStrategy4Singbox"])
        XCTAssertEqual(decoded["inbound"]["udpEnabled"], .bool(true))
        XCTAssertEqual(decoded["inbound"]["localPort"], .number(10809))
    }
    func testLogDisplayPreservesBatchedRecordBoundaries() throws {
        let json = #"{"timestamp":"test","source":"core","message":"first\r\nsecond\nthird","sequence":1}"#
        let entry = try JSONDecoder().decode(LogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.displayMessage, "first\nsecond\nthird")
    }
}
