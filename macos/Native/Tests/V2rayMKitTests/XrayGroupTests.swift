import XCTest
@testable import V2rayMKit

final class XrayGroupTests: XCTestCase {
    func testSpeedTestScopesLegacyAndNestedCustomOutboundDetours() throws {
        let id = UUID()
        let entry = try SettingsValue.parse(#"{"tag":"proxy","protocol":"socks","proxySettings":{"tag":"middle","transportLayer":true}}"#)
        let middle = try SettingsValue.parse(#"{"tag":"middle","protocol":"vless","streamSettings":{"xhttpSettings":{"extra":{"downloadSettings":{"sockopt":{"dialerProxy":"exit"}}}}}}"#)
        let exit = try SettingsValue.parse(#"{"tag":"exit","protocol":"freedom"}"#)
        let config = try NativeLatencyTest.privateConfiguration([entry, middle, exit], id: id, group: XrayGroupRouting(), pingURL: .null)
        let scoped = config["outbounds"].items
        XCTAssertEqual(scoped.map { $0["tag"].text }, ["proxy", "middle", "exit"].map { id.uuidString + "/" + $0 })
        XCTAssertEqual(scoped[0]["proxySettings"]["tag"].text, id.uuidString + "/middle")
        XCTAssertEqual(scoped[0]["proxySettings"]["transportLayer"], .bool(true))
        XCTAssertEqual(scoped[1]["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"]["dialerProxy"].text, id.uuidString + "/exit")
        XCTAssertThrowsError(try NativeLatencyTest.privateConfiguration([entry, exit], id: id, group: XrayGroupRouting(), pingURL: .null)) {
            XCTAssertEqual(($0 as? ClientFailure)?.code, "profile_chain_member_missing")
        }
    }

    func testSubscriptionLinksRequireAUniqueRemarkInEitherDirection() throws {
        func node(_ id: String, _ name: String) -> SettingsValue {
            .object(["indexId": .string(id), "remarks": .string(name), "subid": .string(id)])
        }
        let main = node("main", "Main"), one = node("one", "Shared"), two = node("two", "Shared")
        for key in ["prevProfile", "nextProfile"] {
            let subscriptions = ["main": SettingsValue.object([key: .string("Shared")])]
            for order in [[main, one, two], [main, two, one]] {
                let graph = XrayProfileGraph(nodes: order, subscriptions: subscriptions)
                XCTAssertThrowsError(try graph.root(main)) { error in
                    XCTAssertEqual((error as? ClientFailure)?.code, "profile_chain_member_ambiguous")
                }
            }
            let graph = XrayProfileGraph(nodes: [main, one], subscriptions: subscriptions)
            let child = try SettingsValue.parse(graph.root(main)["protoExtra"].text)
            XCTAssertEqual(child["ChildItems"].text, key == "prevProfile" ? "one,main" : "main,one")
        }
    }

    func testSelectedAndRoutedGroupsPreserveSubscriptionHopsAndBalancingPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO SubItem(Id,PrevProfile,NextProfile) VALUES('sub','Entry','Exit')")
        _ = try db.query("""
            INSERT INTO ProfileItem(IndexId,ConfigType,ConfigVersion,Address,Port,Remarks)
            VALUES('a',4,4,'a.example',1080,'A'),('b',4,4,'b.example',1080,'B'),
                  ('entry',4,4,'entry.example',1080,'Entry'),('exit',4,4,'exit.example',1080,'Exit')
            """)
        _ = try db.query("""
            INSERT INTO ProfileItem(IndexId,ConfigType,ConfigVersion,Subid,Remarks,ProtoExtra)
            VALUES('g',101,4,'sub','Group','{"ChildItems":"a,b","MultipleLoad":"roundrobin"}')
            """)
        _ = try db.query("UPDATE RoutingItem SET RuleSet=?", [.text(#"[{"network":"tcp","outboundProfileId":"g","outboundTag":"Group"}]"#)])
        for tunnel in [nil, "utun5"] as [String?] {
            let config = try await store.generateXrayConfiguration(nodeID: "g", metricsPort: nil, tunnelInterface: tunnel)
            let outbounds = Dictionary(uniqueKeysWithValues: config["outbounds"].items.map { ($0["tag"].text, $0) })
            let balancers = config["routing"]["balancers"].items
            XCTAssertEqual(Set(balancers.map { $0["tag"].text }), ["proxy-balancer", "g-proxy-Group-balancer"])
            for balancer in balancers {
                XCTAssertEqual(balancer["strategy"]["type"].text, "roundRobin")
                let selector = try XCTUnwrap(balancer["selector"].items.first?.text)
                var members = Set<String>()
                for (tag, outbound) in outbounds where tag.hasPrefix(selector) {
                    XCTAssertEqual(outbound["settings"]["address"].text, "exit.example")
                    let hop = try XCTUnwrap(outbounds[outbound["streamSettings"]["sockopt"]["dialerProxy"].text])
                    members.insert(hop["settings"]["address"].text)
                    let entry = try XCTUnwrap(outbounds[hop["streamSettings"]["sockopt"]["dialerProxy"].text])
                    XCTAssertEqual(entry["settings"]["address"].text, "entry.example")
                }
                XCTAssertEqual(members, ["a.example", "b.example"])
            }
        }
    }

    func testPhysicalAndFinalFragmentationKeepChainEdgesAndExistingMasks() throws {
        let settings: SettingsValue = .object([
            "CoreBasicItem": .object(["EnableFragment": .bool(true), "EnableFinalFragment": .bool(true)]),
            "Fragment4RayItem": .object(["Lengths": .array([.string("20-30")]), "Delays": .array([.string("0")]),
                                          "MaxSplit": .string("2-6")])
        ])
        func outbound(_ tag: String, _ security: String) -> SettingsValue {
            .object(["tag": .string(tag), "protocol": .string("socks"),
                     "streamSettings": .object(["security": .string(security)])])
        }
        var exit = outbound("proxy", "tls")
        let entry = outbound("chain-proxy-1", "reality")
        exit["streamSettings"]["sockopt"]["dialerProxy"] = entry["tag"]
        var other = outbound("named-proxy-peer", "tls")
        let preserved: SettingsValue = .array([.object(["type": .string("existing")])])
        other["streamSettings"]["finalmask"]["tcp"] = preserved
        other["streamSettings"]["finalmask"]["udp"] = preserved
        let result = try XrayFragmentation(settings: settings, entryTags: ["proxy", "named-proxy-peer"]).apply(to: [exit, entry, other][...])
        XCTAssertEqual(result.map { $0["tag"].text }, ["proxy","fragment-proxy","chain-proxy-1","named-proxy-peer","fragment-named-proxy-peer"])
        XCTAssertEqual(result.map { $0["streamSettings"]["sockopt"]["dialerProxy"].text },
                       ["fragment-proxy","chain-proxy-1","","fragment-named-proxy-peer",""])
        let masks = result.map { $0["streamSettings"]["finalmask"]["tcp"] }
        XCTAssertEqual(masks[0].items.first?["settings"]["maxSplit"], .string("2-6"))
        XCTAssertEqual(masks[0].items.first?["settings"]["packets"], .string("tlshello"))
        XCTAssertEqual(masks[1], .null)
        XCTAssertEqual(masks[2].items.first?["settings"]["packets"], .string("1-3"))
        XCTAssertEqual(masks[2].items.first?["settings"]["lengths"], .array([.string("20-30")]))
        XCTAssertEqual(masks[4], preserved)
        XCTAssertEqual(result[4]["streamSettings"]["finalmask"]["udp"], preserved)
        XCTAssertThrowsError(try XrayFragmentation.validateLengths([.string("12-24"), .string("0-10")]))
    }

    func testBatchSnapshotKeepsReadGenerationAndNewRequestsSeeEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem(IndexId,ConfigVersion,ConfigType,CoreType,Address,Port) VALUES('example',4,4,2,'127.0.0.1',3128)")
        let snapshot = try await store.configurationSnapshot()
        _ = try db.query("UPDATE ProfileItem SET Port=8888 WHERE IndexId='example'")
        let before = try snapshot.generate(nodeID: "example", metricsPort: nil)
        let after = try await store.generateXrayConfiguration(nodeID: "example", metricsPort: nil)
        func port(_ config: SettingsValue) -> SettingsValue? { config["outbounds"].items.first?["settings"]["port"] }
        XCTAssertEqual(port(before), .number(3128))
        XCTAssertEqual(port(after), .number(8888))
    }

    func testOldGroupTableDynamicSubscriptionFilterAndBrokenGraphs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem (IndexId,ConfigType,ConfigVersion,Remarks,Address,Port,Subid) VALUES ('first',4,4,'JP-1','entry.example',9991,'sub'),('second',4,4,'US-2','exit.example',9992,'sub'),('third',4,4,'JP-3','other.example',9993,'sub'),('g',102,2,'Chain','',0,'')")
        _ = try db.query("INSERT INTO ProfileGroupItem (IndexId,SubChildItems,Filter,ChildItems) VALUES ('g','sub','^JP-','second')")
        let result = try await store.generateXrayConfiguration(nodeID: "g", metricsPort: 40123)
        let hops = result["outbounds"].items.prefix(3)
        XCTAssertEqual(hops.map { $0["settings"]["address"].text }, ["exit.example","other.example","entry.example"])
        XCTAssertEqual(hops.map { $0["streamSettings"]["sockopt"]["dialerProxy"].text }, ["chain-proxy-1-JP-3","chain-proxy-2-JP-1",""])
        XCTAssertTrue(result["dns"]["servers"].items.contains { $0["domains"].items.map(\.text) == ["entry.example","other.example","exit.example"] })
        for (member, expected) in [("g","profile_group_cycle"),("gone","profile_chain_member_missing")] {
            _ = try db.query("UPDATE ProfileGroupItem SET ChildItems=? WHERE IndexId='g'", [.text(member)])
            do {
                _ = try await store.generateXrayConfiguration(nodeID: "g", metricsPort: 40123)
                XCTFail("Broken group accepted")
            } catch let error as ClientFailure { XCTAssertEqual(error.code, expected) }
        }
        XCTAssertEqual(try db.query("SELECT IndexId FROM ProfileItem").count, 4)
    }

    func testInvalidFilterRejectsWholeImportAndStoredGroupEditAndGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let group = try await store.saveSubscription(.object(["remarks": .string("Fixture")]), id: nil)
        let payload: SettingsValue = .object(["ConfigVersion": .number(4), "ConfigType": .number(101),
            "IndexId": .string("g"), "Remarks": .string("invalid"),
            "ProtoExtraObj": .object(["SubChildItems": .string("self"), "Filter": .string("^[A")])])
        let link = "v2rayn://policygroup/" + ProfileTransfer.base64URL(try JSONEncoder().encode(payload))
        do {
            _ = try await store.importProfiles(content: "socks://example.test:1080#A\n" + link, groupID: group.id, isSubscription: false)
            XCTFail("Invalid group filter accepted")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_group_filter_invalid") }
        let empty = try await store.profileCatalog(group: group.id)
        XCTAssertTrue(empty.isEmpty)
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem(IndexId,ConfigType,ConfigVersion,Remarks) VALUES ('g',101,2,'old name')")
        _ = try db.query("INSERT INTO ProfileGroupItem(IndexId,SubChildItems,Filter) VALUES ('g',?,'^[A')", [.text(group.id)])
        _ = try await store.importProfiles(content: "socks://example.test:1080#A\nsocks://example.test:1081#B", groupID: group.id, isSubscription: false)
        let original = try await store.profileDocument(id: "g")
        var edit = original
        edit["remarks"] = .string("new name")
        do {
            try await store.updateProfile(id: "g", original: original, edited: edit)
            XCTFail("Invalid stored filter accepted on edit")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_group_filter_invalid") }
        let retained = try await store.profileDocument(id: "g")
        XCTAssertEqual(retained["remarks"], .string("old name"))
        do {
            _ = try await store.generateXrayConfiguration(nodeID: "g", metricsPort: nil)
            XCTFail("A malformed filter expanded to the full subscription")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_group_filter_invalid") }
        for (filter, count) in [("^A$", 1), ("", 2)] {
            _ = try db.query("UPDATE ProfileGroupItem SET Filter=? WHERE IndexId='g'", [.text(filter)])
            let config = try await store.generateXrayConfiguration(nodeID: "g", metricsPort: nil)
            XCTAssertEqual(config["outbounds"].items.filter { $0["protocol"].text == "socks" }.count, count)
        }
        var invalidEdit = original
        invalidEdit["protoExtra"] = .string(#"{"Filter":"^[A"}"#)
        do {
            try await store.updateProfile(id: "g", original: original, edited: invalidEdit)
            XCTFail("Malformed incoming filter accepted on a valid group")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_group_filter_invalid") }
        try await store.updateProfile(id: "g", original: original, edited: edit)
        let validRename = try await store.profileDocument(id: "g")
        XCTAssertEqual(validRename["remarks"], .string("new name"))
    }

    func testCustomProfilesAndPlaceholderBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let directory = root.appendingPathComponent("guiConfigs")
        let db = try RuntimeDatabase(url: directory.appendingPathComponent("guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem (IndexId,ConfigType,CoreType,Address) VALUES ('c',2,2,'document.json')")
        let document = #"{"outbounds":[{"protocol":"freedom"}],"future":{"large":9007199254740993}}"#
        try Data(document.utf8).write(to: directory.appendingPathComponent("document.json"))
        let generated = try await store.generateXrayConfiguration(nodeID: "c", metricsPort: nil)
        XCTAssertEqual(generated, try SettingsValue.parse(document))
        do {
            _ = try await store.generateXrayConfiguration(nodeID: "c", metricsPort: nil, tunnelInterface: "utun5")
            XCTFail("Raw custom configuration entered the helper path")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "mac_tun_generated_core_required") }
        let custom = try SettingsValue.parse(#"{"protocol":"socks","name":"{{tag}}","streamSettings":{"xhttpSettings":{"extra":{"downloadSettings":{}}}}}"#)
        var tags = XrayCustomOutboundTags(reserving: [])
        let outbound = try XCTUnwrap(XrayFileProfile.outbounds(custom, tag: "tag with quotes \"inside\"", via: "first", bind: "en0", strategy: .string("UseIPv4"), tags: &tags).first)
        XCTAssertEqual(outbound["name"].text, "tag with quotes \"inside\"")
        XCTAssertEqual(outbound["tag"], .null)
        XCTAssertEqual(outbound["streamSettings"]["sockopt"]["dialerProxy"].text, "first")
        XCTAssertEqual(outbound["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"]["interface"].text, "en0")
        XCTAssertEqual(outbound["targetStrategy"].text, "UseIPv4")
    }
}
