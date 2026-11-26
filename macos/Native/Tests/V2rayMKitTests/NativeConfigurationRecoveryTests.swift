import XCTest
@testable import V2rayMKit

final class NativeConfigurationRecoveryTests: XCTestCase {
    func testInterruptedRouteChangeRecoversSettingsAndOpaqueColumnsOnStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("ALTER TABLE RoutingItem ADD COLUMN future BLOB")
        _ = try db.query("UPDATE RoutingItem SET future=?", [.blob(Data([0, 255, 1]))])
        let rows = try db.query("SELECT * FROM RoutingItem ORDER BY rowid")
        let before = try await store.readSettings()
        try await store.beginEdit(table: .routes)
        _ = try db.query("DELETE FROM RoutingItem")
        var broken = before
        broken["IndexId"] = .string("interrupted")
        try await store.writeSettings(broken)
        let reopened = NativeConfigurationStore(dataDirectory: root)
        try await reopened.initializeRuntimeStore()
        let after = try await reopened.readSettings()
        XCTAssertEqual(try db.query("SELECT * FROM RoutingItem ORDER BY rowid"), rows)
        XCTAssertEqual(after, before)
    }

    func testDeletionSelectionReplayAndKibibyteTotalsSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem(IndexId) VALUES ('first'),('next')")
        _ = try db.query("CREATE TABLE NativePendingSelection(Key TEXT PRIMARY KEY, Value TEXT NOT NULL)")
        _ = try db.query("INSERT INTO NativePendingSelection VALUES ('IndexId','next')")
        let now = Date()
        try await store.addTraffic(nodeID: "next", up: 14, down: 23, date: now.addingTimeInterval(-172800))
        try await store.addTraffic(nodeID: "next", up: 5, down: 7, date: now)
        try await store.addTraffic(nodeID: "deleted", up: 1, down: 1, date: now)
        try await store.initializeRuntimeStore()
        let after = try await store.readSettings()
        XCTAssertEqual(after["IndexId"], .string("next"))
        XCTAssertTrue(try db.query("SELECT * FROM NativePendingSelection").isEmpty)
        XCTAssertEqual(try db.query("SELECT TotalUp, TotalDown, TodayUp, TodayDown FROM ServerStatItem"),
                       [["TotalUp": .integer(19), "TotalDown": .integer(30), "TodayUp": .integer(5), "TodayDown": .integer(7)]])
    }
}
