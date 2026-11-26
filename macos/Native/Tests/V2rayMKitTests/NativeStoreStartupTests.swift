import XCTest
@testable import V2rayMKit

final class NativeStoreStartupTests: XCTestCase {
    func testColdStartAndReopenPreserveRulesAndFutureSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let routes = try await store.routingProfiles()
        XCTAssertEqual(routes.count, 3)
        XCTAssertEqual(routes.filter(\.isActive).count, 1)
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem(IndexId, Remarks, ConfigType, Address, Port, Subid) VALUES ('private','local',4,'127.0.0.1',23456,'')")
        var settings = try await store.readSettings()
        settings["futureCounter"] = .integer64(.max)
        try await store.writeSettings(settings)
        try await store.initializeRuntimeStore()
        let after = try await store.readSettings()
        XCTAssertEqual(after["futureCounter"], .integer64(.max))
        XCTAssertEqual(after["IndexId"], .string("private"))
        let catalog = try await store.profileCatalog()
        XCTAssertEqual(catalog.map(\.id), ["private"])
        XCTAssertTrue(catalog[0].isCurrent)
        let loadedRoutes = try await store.routingProfiles()
        XCTAssertEqual(loadedRoutes, routes)
        let config = try await store.generateXrayConfiguration(nodeID: "private", metricsPort: nil)
        XCTAssertEqual(config["outbounds"].items.first?["protocol"], .string("socks"))
        XCTAssertEqual(config["inbounds"].items.first?["listen"], .string("127.0.0.1"))
    }
}
