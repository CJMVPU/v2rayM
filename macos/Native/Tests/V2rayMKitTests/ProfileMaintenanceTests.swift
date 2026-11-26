import XCTest
@testable import V2rayMKit

final class ProfileMaintenanceTests: XCTestCase {
    func testEditingCertificatePinAndNameKeepsLegacyRecordAndFeedsXray() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("""
            INSERT INTO ProfileItem(IndexId,ConfigType,ConfigVersion,Address,Port,Remarks,StreamSecurity,AllowInsecure)
            VALUES('one',4,4,'127.0.0.1',1080,'One','tls','true')
            """)
        let original = try await store.profileDocument(id: "one")
        var draft = original
        draft["verifyPeerCertByName"] = .string("test.example")
        draft["certSha"] = .string("invalid")
        do {
            try await store.updateProfile(id: "one", original: original, edited: draft)
            XCTFail("Invalid pin accepted")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_certificate_pin_invalid") }
        draft["certSha"] = .string(Array(repeating: "AB", count: 32).joined(separator: ":"))
        let saved = try await store.updateProfile(id: "one", original: original, edited: draft)
        XCTAssertEqual(saved["allowInsecure"], .string("true"))
        let config = try await store.generateXrayConfiguration(nodeID: "one", metricsPort: nil)
        let tls = try XCTUnwrap(config["outbounds"].items.first)["streamSettings"]["tlsSettings"]
        XCTAssertEqual(tls["allowInsecure"], .null)
        XCTAssertEqual(tls["pinnedPeerCertSha256"], draft["certSha"])
        XCTAssertEqual(tls["verifyPeerCertByName"], draft["verifyPeerCertByName"])
    }

    func testMaintenanceUsesSelectedGroupAndProtectsSelectedRunningAndUnsupportedRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO SubItem(Id,Remarks) VALUES ('sub','Fixture')")
        for (id,type,group,name) in [("old",4,"sub","Japan"),("new",4,"sub","US"),("elsewhere",4,"other","JP"),
                                     ("selected",4,"sub","Japan"),("serving",4,"sub","US"),("unsupported",8,"sub","US"),
                                     ("excluded",4,"sub","🇩🇪 Remaining 100GB")] {
            _ = try db.query("INSERT INTO ProfileItem (IndexId,ConfigType,Subid,Remarks,Address,Port) VALUES (?,?,?,?,?,1001)",
                             [.text(id),.integer(Int64(type)),.text(group),.text(name),.text(id == "excluded" ? "other.example" : "fixture.example")])
            _ = try db.query("INSERT INTO ProfileExItem (IndexId,Delay) VALUES (?,-1)", [.text(id)])
        }
        var settings = try await store.readSettings()
        settings["GuiItem"]["KeepOlderDedupl"] = .bool(true)
        settings["IndexId"] = .string("selected")
        settings["SubIndexId"] = .string("sub")
        try await store.writeSettings(settings)
        let ids = try await store.generateGroups(subscription: "sub", regions: true)
        XCTAssertEqual(ids.items.count, 2)
        let global = try await store.generateGroups(subscription: "sub", regions: false)
        let config = try await store.generateXrayConfiguration(nodeID: global.text, metricsPort: 40011)
        XCTAssertEqual(config["outbounds"].items.filter { $0["protocol"].text == "socks" }.count, 4)
        let duplicate = try await store.maintainProfiles(group: nil, duplicates: true, serving: "serving")
        XCTAssertEqual(duplicate["removed"].text, "1")
        XCTAssertTrue(try db.query("SELECT * FROM ProfileExItem WHERE IndexId='new'").isEmpty)
        let failed = try await store.maintainProfiles(group: nil, duplicates: false, serving: "serving")
        XCTAssertEqual(failed["removed"].text, "2")
        let left = try db.query("SELECT IndexId FROM ProfileItem WHERE ConfigType <> 101 ORDER BY IndexId")
        XCTAssertEqual(left.compactMap { $0["IndexId"] }, [.text("elsewhere"),.text("selected"),.text("serving"),.text("unsupported")])
    }

    func testDeduplicationKeepsDistinctTLSOptionsAndUnknownFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("ALTER TABLE ProfileItem ADD COLUMN FutureOption TEXT")
        for (id, field, value) in [("base", "Remarks", "base"), ("same", "Remarks", "other name"),
                                   ("name", "VerifyPeerCertByName", "peer.example"), ("pin", "CertSha", "fixture-pin"),
                                   ("ca", "Cert", "fixture-ca"), ("pq", "Mldsa65Verify", "fixture-pq"),
                                   ("ech", "EchConfigList", "fixture-ech"), ("proto", "ProtoExtra", #"{"WgMtu":1392}"#),
                                   ("future", "FutureOption", "opaque")] {
            _ = try db.query("INSERT INTO ProfileItem(IndexId,ConfigVersion,ConfigType,CoreType,Remarks,Address,Port,Network,StreamSecurity,Password) VALUES (?,4,5,2,?,'example.test',443,'raw','tls','fixture-token')", [.text(id), .text(id)])
            _ = try db.query("UPDATE ProfileItem SET " + field + "=? WHERE IndexId=?", [.text(value), .text(id)])
        }
        let before = try await store.generateXrayConfiguration(nodeID: "name", metricsPort: nil)
        XCTAssertEqual(before["outbounds"].items.first?["streamSettings"]["tlsSettings"]["verifyPeerCertByName"].text, "peer.example")
        let result = try await store.maintainProfiles(group: "", duplicates: true, serving: nil)
        XCTAssertEqual(result["removed"].text, "1")
        let kept = try db.query("SELECT IndexId FROM ProfileItem WHERE IndexId NOT IN ('base','same')")
        XCTAssertEqual(kept.count, 7)
    }
}

private extension NativeConfigurationStore {
    func maintainProfiles(group: String?, duplicates: Bool, serving: String?) throws -> SettingsValue {
        let ids = try maintenanceRemovalIDs(group: group, duplicates: duplicates, serving: serving)
        _ = try removeProfiles(ids, subscription: nil)
        return .object(["removed": .number(Double(ids.count))])
    }
}
