import XCTest
@testable import V2rayMKit

final class SubscriptionEditingTests: XCTestCase {
    func testReadingSpecificSubscriptionIsIndependentOfUnrelatedMalformedRows() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let store = NativeConfigurationStore(dataDirectory: data)
        try await store.initializeRuntimeStore()
        let good = try await store.saveSubscription(.object(["remarks": .string("Good")]), id: nil)
        let bad = try await store.saveSubscription(.object(["remarks": .string("Other")]), id: nil)
        let db = try RuntimeDatabase(url: data.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("UPDATE SubItem SET AutoUpdateInterval='invalid' WHERE Id=?", [.text(bad.id)])
        let read = try await store.subscription(id: good.id)
        XCTAssertEqual(read, good)
        do { _ = try await store.subscription(id: bad.id); XCTFail("Malformed record should report an error") }
        catch is DecodingError {}
        do { _ = try await store.subscription(id: "missing"); XCTFail("Missing record should report an error") }
        catch let failure as ClientFailure { XCTAssertEqual(failure.code, "subscription_not_found") }
    }

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
