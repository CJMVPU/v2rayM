import XCTest
import SQLite3
@testable import V2rayMKit

final class RuntimeDatabaseTests: XCTestCase {
    func testSettingsPreserveUnsigned64BitValuesAcrossSave() throws {
        for token in ["9223372036854775808", "9223372036854775809", "18446744073709551615"] {
            var settings = try SettingsValue.parse("{\"futureOption\":" + token + "}")
            settings["edited"] = .bool(true)
            let restored = try SettingsValue.parse(settings.json())
            XCTAssertEqual(restored["futureOption"].text, token)
            XCTAssertEqual(try restored["futureOption"].json(), token)
        }
    }

    func testOldDatabasePreservesIdentityAndOrdersRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = root.appendingPathComponent("guiConfigs")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = config.appendingPathComponent("guiNDB.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        sqlite3_close(handle)
        let db = try RuntimeDatabase(url: url, writable: true)
        _ = try db.query("CREATE TABLE ProfileItem(IndexId TEXT PRIMARY KEY, ConfigType INT, CoreType INT, MuxEnabled INT, FutureField BLOB, Remarks TEXT)")
        let id = "A' OR 1=1 --"
        let secret = Data([7, 0, 255])
        _ = try db.query("INSERT INTO ProfileItem VALUES (?, 5, 2, 1, ?, ?)", [.text(id), .blob(secret), .text("中文\u{0}名称")])
        _ = try db.query("CREATE TABLE RoutingItem(Id TEXT PRIMARY KEY, Remarks TEXT, Sort INT, IsActive INT)")
        _ = try db.query("INSERT INTO RoutingItem VALUES ('b','second',2,0), ('a','first',1,1)")
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.prepareDatabase()
        try await store.prepareDatabase()
        _ = try db.query("UPDATE ProfileItem SET Address = '127.0.0.1', Port = 34567")
        let profile = try await store.profileDocument(id: id)
        XCTAssertEqual(profile["configType"], .string("vless"))
        XCTAssertEqual(profile["remarks"], .string("中文\u{0}名称"))
        XCTAssertEqual(profile["muxEnabled"], .bool(true))
        XCTAssertEqual(profile["coreType"], .string("xray"))
        let routes = try await store.routingProfiles()
        XCTAssertEqual(routes.map(\.id), ["a", "b"])
        XCTAssertEqual(routes.map(\.isActive), [true, false])
        XCTAssertThrowsError(try db.transaction {
            _ = try db.query("UPDATE ProfileItem SET Remarks='changed'")
            _ = try db.query("INSERT INTO ProfileItem(IndexId) VALUES (?)", [.text(id)])
        })
        let row = try XCTUnwrap(db.query("SELECT Remarks, FutureField FROM ProfileItem").first)
        XCTAssertEqual(row["Remarks"], .text("中文\u{0}名称"))
        XCTAssertEqual(row["FutureField"], .blob(secret))
        var edited = profile
        edited["remarks"] = .string("updated")
        try await store.updateProfile(id: id, original: profile, edited: edited)
        XCTAssertEqual(try db.query("SELECT Remarks, FutureField FROM ProfileItem").first,
                       ["Remarks": .text("updated"), "FutureField": .blob(secret)])
        edited["remarks"] = .string("stale edit")
        do {
            try await store.updateProfile(id: id, original: profile, edited: edited)
            XCTFail("Stale editor should report a conflict")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_edit_conflict") }

    }
}
