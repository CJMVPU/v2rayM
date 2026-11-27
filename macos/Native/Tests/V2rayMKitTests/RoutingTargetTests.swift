import Foundation
import XCTest
@testable import V2rayMKit

final class RoutingTargetTests: XCTestCase {
    func testMigrationBindsUniqueNamesAndPreservesUnresolvedRulesAndUnknownFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        for (id, name) in [("A", "Default"), ("B", "Edge"), ("C", "Duplicate"), ("D", "Duplicate")] {
            _ = try db.query("INSERT INTO ProfileItem(IndexId,ConfigType,ConfigVersion,Remarks,Address,Port) VALUES (?,4,4,?,'127.0.0.1',8080)", [.text(id), .text(name)])
        }
        let legacy = #"[{"OutboundTag":"Edge","Port":"123","Opaque":"keep"},{"OutboundTag":"Duplicate","Port":"80","Enabled":false},{"OutboundTag":"Missing","Port":"81","Enabled":false}]"#
        _ = try db.query("UPDATE RoutingItem SET RuleSet=?", [.text(legacy)])
        try await store.initializeRuntimeStore()
        let plans = try await store.routingProfiles()
        let routeID = try XCTUnwrap(plans.first(where: \.isActive)?.id)
        let migrated = try await store.routingRules(id: routeID)
        XCTAssertEqual(migrated[0]["outboundProfileId"], .string("B"))
        XCTAssertEqual(migrated[0]["Opaque"], .string("keep"))
        XCTAssertEqual(migrated[1]["outboundProfileId"], .null)
        XCTAssertEqual(migrated[2]["outboundProfileId"], .null)
        _ = try db.query("UPDATE ProfileItem SET Remarks='New name' WHERE IndexId='B'")
        _ = try db.query("UPDATE ProfileItem SET Remarks='Edge' WHERE IndexId='C'")
        let config = try await store.generateXrayConfiguration(nodeID: "A", metricsPort: nil)
        XCTAssertEqual(config["routing"]["rules"].items.first?["outboundTag"], .string("B-proxy-New name"))
        _ = try db.query("DELETE FROM ProfileItem WHERE IndexId='B'")
        do {
            _ = try await store.generateXrayConfiguration(nodeID: "A", metricsPort: nil)
            XCTFail("A stale ID must not be re-bound to the old display name")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "routing_target_missing") }
    }

    func testEditorAndImportedRulesRejectMissingOrAmbiguousTargetsWithoutOverwritingPriorPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable:true)
        for (id,name) in [("1","Edge"),("2","Peer"),("3","Peer"),("4","direct")] {
            _ = try db.query("INSERT INTO ProfileItem(IndexId,ConfigType,Remarks,Address,Port) VALUES(?,4,?,'127.0.0.1',8080)", [.text(id),.text(name)])
        }
        let r = try await store.saveRoute(.object(["remarks": .string("rule"), "ruleSet": .string(#"[{"OutboundTag":"Edge","Port":"80"}]"#)]))
        let id = r
        let prior = try await store.routingRules(id: id)
        XCTAssertEqual(prior[0]["outboundProfileId"], .string("1"))
        for (name,code) in [("None","routing_target_missing"),("Peer","routing_target_ambiguous")] {
            do {
                try await store.editRules(id, edit: .save(.array([.object(["outboundTag": .string(name), "port":.string("80")])]), append: true))
                XCTFail("Invalid imported route committed")
            } catch let error as ClientFailure { XCTAssertEqual(error.code, code) }
            let after = try await store.routingRules(id:id)
            XCTAssertEqual(after, prior)
        }
        var explicit = prior[0]
        explicit["outboundTag"] = .string("direct")
        explicit["outboundProfileId"] = .string("4")
        try await store.editRules(id, edit:.save(.array([explicit]), append:false))
        try await store.selectRoute(id, delete:false)
        let config = try await store.generateXrayConfiguration(nodeID:"1",metricsPort:nil)
        XCTAssertEqual(config["routing"]["rules"].items.first?["outboundTag"], .string("4-proxy-direct"))
    }
}
