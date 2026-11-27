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

    func testBasicEditingRetainsAdvancedSubscriptionOptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeRuntimeHost(dataDirectory: root, mayContactHelper: false, automaticMaintenance: false)
        try await host.start()
        do {
            let advanced = try SettingsValue.parse(#"{"remarks":"Original","url":"https://example.invalid/sub","moreUrl":"https://example.invalid/more","filter":"keep-filter","autoUpdateInterval":60,"userAgent":"custom-agent","requestHeaders":"{\"X-Fixture\":\"value\"}","convertTarget":"singbox","memo":"keep-memo","sort":7,"prevProfile":"before","nextProfile":"after","preSocksPort":10800}"#)
            let created = try await host.saveSubscription(id: nil, advanced)
            let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
            _ = try db.query("UPDATE SubItem SET CustomCoreType=24 WHERE Id=?", [.text(created.id)])
            var expected = try await host.subscription(id: created.id)
            expected.remarks = "Edited"
            expected.url = "https://example.invalid/new"
            expected.enabled = false
            let updated = try await host.saveSubscription(id: created.id, .object([
                "remarks": .string(expected.remarks), "url": .string(expected.url), "enabled": .bool(false)]))
            XCTAssertEqual(updated, expected)
            let stored = try await host.subscription(id: created.id)
            XCTAssertEqual(stored, expected)
        } catch { try await host.stop(); throw error }
        try await host.stop()
    }
}
