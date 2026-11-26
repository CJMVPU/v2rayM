import Foundation
import XCTest
@testable import V2rayMKit

final class CustomOutboundChainTests: XCTestCase {
    private func inner(_ value: SettingsValue) throws -> String {
        let document: SettingsValue = .object(["ConfigVersion": .number(4), "ConfigType": .number(13),
            "Remarks": .string("fixture chain"), "CoreType": .number(2), "CustomOutboundObj": value])
        return "v2rayn://outbound/" + ProfileTransfer.base64URL(try JSONEncoder().encode(document))
    }

    private func outbound(_ name: String, port: Int) -> SettingsValue {
        .object(["tag": .string(name), "protocol": .string("http"), "settings": .object([
            "servers": .array([.object(["address": .string("127.0.0.1"), "port": .number(Double(port))])])])])
    }

    func testTypedChainRoundTripAndUntypedBatchesRemainSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        var first = outbound("exit", port: 9)
        first["streamSettings"]["sockopt"]["dialerProxy"] = .string("direct")
        let chain = SettingsValue.array([first, outbound("direct", port: 8)])
        let count = try await store.importProfiles(content: inner(chain), groupID: nil, isSubscription: false)
        XCTAssertEqual(count, 1)
        let catalog = try await store.profileCatalog()
        let id = try XCTUnwrap(catalog.first?.id)
        let config = try await store.generateXrayConfiguration(nodeID: id, metricsPort: nil)
        let nodes = config["outbounds"].items
        XCTAssertEqual(Set(nodes.map { $0["tag"].text }).count, nodes.count)
        XCTAssertEqual(nodes[0]["tag"].text, "proxy")
        XCTAssertEqual(nodes[0]["streamSettings"]["sockopt"]["dialerProxy"], nodes[1]["tag"])
        XCTAssertNotEqual(nodes[1]["tag"].text, "direct")
        // Nest the same saved custom chain twice, so each instance needs independent internal tags.
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        let children = try SettingsValue.object(["ChildItems": .string(id + "," + id)]).json()
        _ = try db.query("INSERT INTO ProfileItem(IndexId,ConfigType,ConfigVersion,Remarks,ProtoExtra) VALUES ('group',102,4,'Group',?)", [.text(children)])
        let nested = try await store.generateXrayConfiguration(nodeID: "group", metricsPort: nil)
        var pointer = "proxy", visited = Set<String>(), ports = [String]()
        while !pointer.isEmpty {
            let hop = try XCTUnwrap(nested["outbounds"].items.first { $0["tag"].text == pointer })
            guard visited.insert(pointer).inserted else { return XCTFail("Cycle in expanded group") }
            ports.append(try XCTUnwrap(hop["settings"]["servers"].items.first)["port"].text)
            pointer = hop["streamSettings"]["sockopt"]["dialerProxy"].text
        }
        XCTAssertEqual(ports, ["9", "8", "9", "8"])
        let exported = try await store.exportProfiles(.object(["profileIds": .array([.string(id)]), "includeInnerUri": .bool(true),
            "includeShareUris": .bool(false), "includeClientConfig": .bool(false)]), metricsPort: 9000)
        let url = try XCTUnwrap(URLComponents(string: XCTUnwrap(exported.first)["content"].text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let restored = try SettingsValue.parse(XCTUnwrap(ShareLinkImport.base64Text(String(url.path.dropFirst()))))
        XCTAssertEqual(restored["CustomOutboundObj"], chain)
        XCTAssertEqual(restored["Address"], .null)
        let raw = try await store.importProfiles(content: chain.json(), groupID: nil, isSubscription: false)
        XCTAssertEqual(raw, 2)
        for malformed in [SettingsValue.array([]), .array([first, .null]), .array([first, first]), .array([first, .object(["protocol": .string("unknown")])])] {
            XCTAssertThrowsError(try ShareLinkImport.decode(inner(malformed)))
        }
    }

    func testNestedHopsResolvePlaceholdersAndLocalTagsIndependently() throws {
        var exit = outbound("{{tag}}", port: 9)
        exit["proxySettings"]["tag"] = .string("local-peer")
        exit["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"]["dialerProxy"] = .string("local-peer")
        var terminal = outbound("local-peer", port: 8)
        terminal["streamSettings"]["sockopt"]["dialerProxy"] = .string("{{detour}}")
        terminal["streamSettings"]["sockopt"]["interface"] = .string("{{interface}}")
        var tags = XrayCustomOutboundTags(reserving: ["custom-hop-1", "direct", "proxy-a", "proxy-b"])
        let chain = SettingsValue.array([exit, terminal])
        let a = try XrayFileProfile.outbounds(chain, tag: "proxy-a", via: "outer", bind: "en7", strategy: .string("UseIP"), tags: &tags)
        let b = try XrayFileProfile.outbounds(chain, tag: "proxy-b", via: "outer", bind: "en7", strategy: .null, tags: &tags)
        XCTAssertEqual(Set((a + b).map { $0["tag"].text }).count, 4)
        XCTAssertFalse(a[1]["tag"].text.hasPrefix("proxy"))
        XCTAssertNotEqual(a[1]["tag"].text, "custom-hop-1")
        XCTAssertEqual(a[0]["proxySettings"]["tag"], a[1]["tag"])
        XCTAssertEqual(b[0]["proxySettings"]["tag"], b[1]["tag"])
        XCTAssertEqual(a[0]["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"]["dialerProxy"], a[1]["tag"])
        XCTAssertEqual(a[0]["targetStrategy"].text, "UseIP")
        XCTAssertEqual(a[1]["targetStrategy"], .null)
        XCTAssertEqual(a[1]["streamSettings"]["sockopt"]["dialerProxy"].text, "outer")
        XCTAssertEqual(a[1]["streamSettings"]["sockopt"]["interface"].text, "en7")
    }

    func testExplicitPlaceholdersAnywhereSuppressAutomaticTerminalOverrides() throws {
        var exit = outbound("exit", port: 9)
        exit["streamSettings"]["sockopt"]["interface"] = .string("{{interface}}")
        exit["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"]["dialerProxy"] = .string("{{detour}}")
        var tags = XrayCustomOutboundTags(reserving: [])
        let results = try XrayFileProfile.outbounds(.array([exit, outbound("other", port: 8)]), tag: "proxy",
                                                     via: "outer-hop", bind: "lo0", strategy: .null, tags: &tags)
        XCTAssertEqual(results[0]["streamSettings"]["sockopt"]["interface"], .string("lo0"))
        XCTAssertEqual(results[0]["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"]["dialerProxy"], .string("outer-hop"))
        XCTAssertEqual(results[1]["streamSettings"], .null)
    }

    func testOuterTemplateRespectsProxySettingsAndReservesItsTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        var exit = outbound("exit", port: 9)
        exit["proxySettings"]["tag"] = .string("entry")
        _ = try await store.importProfiles(content: inner(.array([exit, outbound("entry", port: 8)])), groupID: nil, isSubscription: false)
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        let template = #"{"outbounds":[{"tag":"custom-hop-1","protocol":"freedom"}]}"#
        _ = try db.query("UPDATE FullConfigTemplateItem SET Enabled=1, Config=?, ProxyDetour='custom-hop-1' WHERE CoreType=2", [.text(template)])
        let catalog = try await store.profileCatalog()
        let generated = try await store.generateXrayConfiguration(nodeID: XCTUnwrap(catalog.first?.id), metricsPort: nil)
        let nodes = generated["outbounds"].items
        XCTAssertEqual(Set(nodes.map { $0["tag"].text }).count, nodes.count)
        XCTAssertEqual(nodes[0]["proxySettings"]["tag"], nodes[1]["tag"])
        XCTAssertEqual(nodes[0]["streamSettings"]["sockopt"]["dialerProxy"], .null)
        XCTAssertEqual(nodes[1]["streamSettings"]["sockopt"]["dialerProxy"], .string("custom-hop-1"))
    }

    func testPackagedCoreTraversesBothPeersAndReachesHTTP() async throws {
        guard let bundle = ProcessInfo.processInfo.environment["V2RAYM_TEST_SIGNED_APP"] else {
            throw XCTSkip("Set V2RAYM_TEST_SIGNED_APP to run the packaged two-hop loopback")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "custom-outbound-loopback", withExtension: "py", subdirectory: "Fixtures"))
        let peers = Process(), input = Pipe(), output = Pipe()
        peers.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        peers.arguments = [fixture.path]
        peers.standardInput = input
        peers.standardOutput = output
        try peers.run()
        defer {
            try? input.fileHandleForWriting.close()
            if peers.isRunning { peers.terminate() }
            peers.waitUntilExit()
        }
        let ports = try JSONDecoder().decode([String: Int].self, from: output.fileHandleForReading.availableData)
        let entry = try XCTUnwrap(ports["entry"]), exit = try XCTUnwrap(ports["exit"]), inbound = try XCTUnwrap(ports["inbound"])
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        var end = outbound("exit", port: exit)
        end["streamSettings"]["sockopt"]["dialerProxy"] = .string("entry")
        let count = try await store.importProfiles(content: inner(.array([end, outbound("entry", port: entry)])), groupID: nil, isSubscription: false)
        XCTAssertEqual(count, 1)
        let catalog = try await store.profileCatalog()
        var settings = try await store.readSettings()
        settings["IndexId"] = .string(try XCTUnwrap(catalog.first?.id))
        var listener = try XCTUnwrap(settings["Inbound"].items.first)
        listener["LocalPort"] = .number(Double(inbound))
        listener["SniffingEnabled"] = .bool(false)
        settings["Inbound"] = .array([listener])
        try await store.writeSettings(settings)
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("UPDATE RoutingItem SET RuleSet=?, RuleNum=1 WHERE IsActive=1", [.text(#"[{"port":"1-65535","outboundTag":"proxy","enabled":true}]"#)])
        let host = NativeRuntimeHost(bundle: URL(fileURLWithPath: bundle), dataDirectory: root, mayContactHelper: false, automaticMaintenance: false)
        _ = try await host.startClient()
        do {
            try await host.startTunCore()
            try input.fileHandleForWriting.write(contentsOf: Data("run\n".utf8))
            let evidence = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            peers.waitUntilExit()
            XCTAssertEqual(peers.terminationStatus, 0, evidence)
            print("CustomOutbound loopback: " + evidence)
        } catch {
            try await host.stop()
            throw error
        }
        try await host.stop()
    }
}
