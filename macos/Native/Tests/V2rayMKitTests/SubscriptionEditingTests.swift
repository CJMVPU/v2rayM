import XCTest
@testable import V2rayMKit

final class SubscriptionEditingTests: XCTestCase {
    func testBasicEditingRetainsAdvancedSubscriptionOptions() throws {
        let json = #"{"id":"fixture","remarks":"Original","url":"https://example.invalid/sub","enabled":true,"moreUrl":"https://example.invalid/more","filter":"keep-filter","autoUpdateInterval":60,"updateTime":0,"userAgent":"custom-agent","requestHeaders":"X-Fixture: value","convertTarget":"singbox","memo":"keep-memo","sort":7,"prevProfile":"before","nextProfile":"after","preSocksPort":10800,"customCoreType":"sing_box"}"#
        let original = try JSONDecoder().decode(Subscription.self, from: Data(json.utf8))
        let edited = SubscriptionInput(name: "Edited", url: "https://example.invalid/new", enabled: false, existing: original)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for key in ["moreUrl", "filter", "autoUpdateInterval", "userAgent", "requestHeaders", "convertTarget", "memo", "sort", "prevProfile", "nextProfile", "preSocksPort", "customCoreType"] {
            XCTAssertEqual(String(describing: result[key]!), String(describing: before[key]!), key)
        }
        XCTAssertEqual(result["remarks"] as? String, "Edited")
        XCTAssertEqual(result["url"] as? String, "https://example.invalid/new")
        XCTAssertEqual(result["enabled"] as? Bool, false)
    }
}
