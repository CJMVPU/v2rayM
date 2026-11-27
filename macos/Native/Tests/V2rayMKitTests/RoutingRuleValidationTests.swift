import Foundation
import XCTest
@testable import V2rayMKit

final class RoutingRuleValidationTests: XCTestCase {
    func testImportAndSaveRejectInvalidSelectorsAndPreservePreviousRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let valid = #"[{"Domain":["full:only.example"],"Port":"443","OutboundTag":"direct"}]"#
        let input = try SettingsValue.object(["remarks": .string("test"), "ruleSet": SettingsValue.parse(valid)])
        let route = try await store.saveRoute(input)
        let id = route
        let original = try await store.routingRules(id: id)

        let invalid = #"[{"Domain":"full:only.example","Port":"443","OutboundTag":"direct"}]"#
        var replacement = input
        replacement["ruleSet"] = .string(invalid)
        do {
            _ = try await store.saveRoute(replacement, id: id)
            XCTFail("Accepted an invalid route")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "routing_rule_field_invalid") }
        for append in [true, false] {
            do {
                let imported = try NativeConfigurationStore.parseRoutingRules(invalid)
                try await store.editRules(id, edit: .save(imported, append: append))
                XCTFail("Accepted an invalid import")
            } catch let error as ClientFailure { XCTAssertEqual(error.code, "routing_rule_field_invalid") }
        }
        replacement["ruleSet"] = .object(["domain": .string("full:only.example")])
        do {
            _ = try await store.saveRoute(replacement, id: id)
            XCTFail("Replaced existing rules with an empty list")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "routing_rules_json_invalid") }
        let after = try await store.routingRules(id: id)
        XCTAssertEqual(after, original)

        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("UPDATE RoutingItem SET RuleSet=? WHERE Id=?", [.text(invalid), .text(id)])
        try await store.selectRoute(id, delete: false)
        let snapshot = try await store.configurationSnapshot()
        let config = snapshot.configuration
        XCTAssertThrowsError(try XrayRouting.generate(config: config.settings, profile: config.route, tunProcesses: nil) { tag, _ in tag })
        let stored = try await store.routingRules(id: id)
        XCTAssertEqual(stored.first?["domain"], .string("full:only.example"))
        _ = try await store.saveRoute(input, id: id)
        let corrected = try await store.configurationSnapshot()
        let rules = try XrayRouting.generate(config: config.settings, profile: corrected.configuration.route, tunProcesses: nil) { tag, _ in tag }
        XCTAssertEqual(rules["rules"].items.first?["domain"], .array([.string("full:only.example")]))
        XCTAssertEqual(rules["rules"].items.first?["port"], .string("443"))
    }

    func testDNSAndProxyRejectInvalidFieldTypesInLegacyRules() throws {
        let dns = XrayDNS(simple: .null, custom: .null, protectedDomains: [], systemHosts: [:], useTunnel: false)
        var invalid: [(String, SettingsValue)] = [
            ("network", .array([.string("tcp")])), ("port", .bool(true)), ("enabled", .string("false")), ("ruleType", .string("invalid"))
        ]
        for key in ["domain", "ip", "process", "inboundTag", "protocol"] {
            invalid.append((key, .string("one")))
            invalid.append((key, .array([.object([:])])))
        }
        for (key, bad) in invalid {
            var rule = SettingsValue.object(["outboundTag": .string("direct"), "port": .string("443"), "ruleType": .number(2)])
            rule[key] = bad
            let profile = try SettingsValue.object(["RuleSet": .string(SettingsValue.array([rule]).json())])
            var config = SettingsValue.object([:])
            XCTAssertThrowsError(try dns.apply(to: &config, routingProfile: profile)) { error in
                XCTAssertTrue(error.localizedDescription.contains(key))
            }
            XCTAssertThrowsError(try XrayRouting.generate(config: config, profile: profile, tunProcesses: []) { tag, _ in tag })
        }
    }

    func testNullAndDisabledLegacySelectorsRemainUsable() throws {
        let profile = SettingsValue.object(["RuleSet": .string(#"[{"DOMAIN":null,"IP":[],"Enabled":true,"Port":443},{"Enabled":false,"Domain":"malformed","Port":"80"}]"#)])
        let rules = try XrayRouting.generate(config: .null, profile: profile, tunProcesses: nil) { tag, _ in tag }
        XCTAssertEqual(rules["rules"].items.count, 1)
        XCTAssertEqual(rules["rules"].items.first?["port"], .number(443))
    }
}
