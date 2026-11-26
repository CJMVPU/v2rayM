import XCTest
@testable import V2rayMKit

final class LegacyTransferTests: XCTestCase {
    func testOldBackendExportsImportedIntoFreshDatabaseGenerateSameOutbound() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "legacy-inner", withExtension: "json", subdirectory: "Fixtures"))
        let examples = try JSONDecoder().decode([SettingsValue].self, from: Data(contentsOf: fixture))
        for example in examples {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = NativeConfigurationStore(dataDirectory: root)
            try await store.initializeRuntimeStore()
            let uri = example["inner"].text
            let parts = try XCTUnwrap(URLComponents(string: uri))
            let payload = try SettingsValue.parse(XCTUnwrap(ShareLinkImport.base64Text(String(parts.path.dropFirst()))))
            let imported = try await store.importProfiles(content: uri, groupID: nil, isSubscription: false)
            XCTAssertEqual(imported, 1)
            let nodes = try await store.profileCatalog()
            let node = try XCTUnwrap(nodes.first)
            XCTAssertNotEqual(node.id, payload["IndexId"].text)
            let config = try await store.generateXrayConfiguration(nodeID: node.id, metricsPort: 21234)
            XCTAssertEqual(config["outbounds"].items.first, example["expected"], example["name"].text)
        }
    }

    func testNestedInnerGroupsSurviveSubscriptionRefreshAndFreshImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeConfigurationStore(dataDirectory: directory)
        try await store.initializeRuntimeStore()
        let group = try await store.saveSubscription(.object(["remarks": .string("Fixture"), "url": .string("http://127.0.0.1/feed")]), id: nil)
        func uri(_ kind: Int, _ type: String, _ id: String, _ extra: SettingsValue = .null) throws -> String {
            var doc: SettingsValue = .object(["ConfigVersion": .number(4), "ConfigType": .number(Double(kind)), "IndexId": .string(id),
                                               "Remarks": .string(id), "CoreType": .number(2)])
            if kind == 4 {
                doc["Address"] = .string("127.0.0.1")
                doc["Port"] = .number(id == "first" ? 41001 : 41002)
                doc["Network"] = .string("tcp")
            } else { doc["ProtoExtraObj"] = extra }
            return "v2rayn://" + type + "/" + ProfileTransfer.base64URL(try JSONEncoder().encode(doc))
        }
        let links = try [uri(101, "policygroup", "group", .object(["ChildItems": .string("chain"), "MultipleLoad": .number(2)])),
                         uri(102, "proxychain", "chain", .object(["ChildItems": .string("second,first")])),
                         uri(4, "socks", "first"), uri(4, "socks", "second")].joined(separator: "\n")
        try await store.replaceSubscription(group, rows: ShareLinkImport.decode(links), serving: nil)
        let original = try await store.profileCatalog(group: group.id)
        let initial = Dictionary(uniqueKeysWithValues: original.map { ($0.remarks, $0.id) })
        let chain = try await store.profileDocument(id: XCTUnwrap(initial["chain"]))
        let memberIDs = try [XCTUnwrap(initial["second"]), XCTUnwrap(initial["first"])].joined(separator: ",")
        XCTAssertEqual(try SettingsValue.parse(chain["protoExtra"].text)["ChildItems"].text, memberIDs)
        let subscriptions = try await store.subscriptions()
        try await store.replaceSubscription(XCTUnwrap(subscriptions.first), rows: ShareLinkImport.decode(links), serving: initial["group"])
        let refreshed = try await store.profileCatalog(group: group.id)
        XCTAssertEqual(initial, Dictionary(uniqueKeysWithValues: refreshed.map { ($0.remarks, $0.id) }))
        let groupID = try XCTUnwrap(initial["group"])
        let config = try await store.generateXrayConfiguration(nodeID: groupID, metricsPort: 21020)
        let documents = try await store.exportProfiles(.object(["profileIds": .array(original.map { .string($0.id) }),
            "includeInnerUri": .bool(true), "includeShareUris": .bool(false), "includeClientConfig": .bool(false)]), metricsPort: 21020)
        let exported = try XCTUnwrap(documents.first)["content"].text
        let imported = try await store.importProfiles(content: exported, groupID: "", isSubscription: false)
        XCTAssertEqual(imported, 4)
        let all = try await store.profileCatalog()
        let copy = try XCTUnwrap(all.first { $0.remarks == "group" && $0.id != groupID })
        let regenerated = try await store.generateXrayConfiguration(nodeID: copy.id, metricsPort: 21020)
        XCTAssertEqual(regenerated["outbounds"], config["outbounds"])
        let invalid = try uri(102, "proxychain", "foreign", .object(["ChildItems": .string(groupID)]))
        do {
            _ = try await store.importProfiles(content: invalid, groupID: group.id, isSubscription: false)
            XCTFail("External IDs cannot point into the existing database")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_chain_member_missing") }
        let final = try await store.profileCatalog()
        XCTAssertEqual(final.count, all.count)
    }

    func testShareExportsOnlyActiveTransportAfterEditingNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        for scheme in ["vless","trojan"] {
            _ = try await store.importProfiles(content: "\(scheme)://abc@127.0.0.1:443?type=grpc&mode=multi&serviceName=svc#\(scheme)",
                                               groupID: "", isSubscription: false)
            let rows = try await store.profileCatalog()
            let original = try XCTUnwrap(rows.first { $0.remarks == scheme })
            let old = try await store.profileDocument(id: original.id)
            var edited = old
            var transport = try SettingsValue.parse(old["transportExtra"].text)
            transport["XhttpMode"] = .string("stream-up")
            edited["network"] = .string("xhttp")
            edited["transportExtra"] = .string(try transport.json())
            try await store.updateProfile(id: original.id, original: old, edited: edited)
            let documents = try await store.exportProfiles(.object(["profileIds": .array([.string(original.id)]),
                "includeClientConfig": .bool(false)]), metricsPort: 21020)
            let link = try XCTUnwrap(documents.first)["content"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = try XCTUnwrap(URLComponents(string: link)?.queryItems)
            XCTAssertEqual(query.filter { $0.name == "mode" }.map(\.value), ["stream-up"])
            XCTAssertFalse(query.contains { $0.name == "serviceName" })
            _ = try await store.importProfiles(content: link, groupID: "", isSubscription: false)
            let restored = try await store.profileCatalog()
            let copy = try XCTUnwrap(restored.first { $0.remarks == scheme && $0.id != original.id })
            for id in [original.id, copy.id] {
                let config = try await store.generateXrayConfiguration(nodeID: id, metricsPort: nil)
                XCTAssertEqual(config["outbounds"].items.first?["streamSettings"]["xhttpSettings"]["mode"], .string("stream-up"))
            }
        }
    }

    func testVmessQRCodePreservesGrpcAndCredentials() throws {
        let qr: SettingsValue = .object(["add": .string("localhost"), "port": .string("443"), "id": .string(UUID().uuidString),
                                         "net": .string("grpc"), "type": .string("multi"), "host": .string("local.test"),
                                         "path": .string("grpc-test"), "scy": .string("auto"), "tls": .string("tls")])
        let original = "vmess://" + (try JSONEncoder().encode(qr)).base64EncodedString()
        let row = try XCTUnwrap(ShareLinkImport.decode(original).first)
        let doc = NativeConfigurationStore.nodeDocument(from: row)
        let exported = try XCTUnwrap(ProfileTransfer.share(doc))
        let output = try XCTUnwrap(ShareLinkImport.decode(exported).first)
        XCTAssertEqual(output, row)
        XCTAssertEqual(try SettingsValue.parse(doc["transportExtra"].text)["GrpcServiceName"], .string("grpc-test"))
    }

    func testHysteriaAndShadowsocksLinks() throws {
        let hy = try XCTUnwrap(ShareLinkImport.decode("hy2://test%3Akey@localhost?obfs=gecko&obfs-password=shared&pinSHA256=example").first)
        let doc = NativeConfigurationStore.nodeDocument(from: hy)
        XCTAssertEqual(doc["port"], .number(443))
        XCTAssertEqual(doc["password"], .string("test:key"))
        XCTAssertEqual(doc["certSha"], .string("example"))
        XCTAssertEqual(try SettingsValue.parse(doc["protoExtra"].text)["GeckoMinPacketSize"], .string("512"))
        let plugin = "v2ray-plugin;mode=websocket;host=localhost;path=/ws;tls;mux=0"
        let ss = try XCTUnwrap(ShareLinkImport.decode("ss://YWVzLTEyOC1nY206bG9jYWw@localhost:3421?plugin=" + plugin).first)
        let socks = NativeConfigurationStore.nodeDocument(from: ss)
        XCTAssertEqual(socks["streamSecurity"], .string("tls"))
        XCTAssertEqual(try SettingsValue.parse(socks["transportExtra"].text)["Path"], .string("/ws"))
    }
}
