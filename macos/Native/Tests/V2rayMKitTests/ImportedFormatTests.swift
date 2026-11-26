import XCTest
@testable import V2rayMKit

final class ImportedFormatTests: XCTestCase {
    func testSIP008VariantsProduceShadowsocksOutbounds() throws {
        for port in ["8388", "\"8388\""] {
            let server = """
            {"server":"proxy.example","server_port":\(port),"password":"p%41","method":"aes-128-gcm","remarks":"example"}
            """
            for document in ["[\(server)]", "{\"version\":1,\"servers\":[\(server)]}"] {
                let rows = try ShareLinkImport.decode(document)
                XCTAssertEqual(rows.count, 1)
                let node = NativeConfigurationStore.nodeDocument(from: try XCTUnwrap(rows.first))
                XCTAssertEqual(node["remarks"].text, "example")
                let outbound = try XrayOutbound(node: node, config: .object([:])).build()
                let target = outbound["settings"]
                XCTAssertEqual(outbound["protocol"].text, "shadowsocks")
                XCTAssertEqual(target["address"].text, "proxy.example")
                XCTAssertEqual(target["port"].text, "8388")
                XCTAssertEqual(target["method"].text, "aes-128-gcm")
                XCTAssertEqual(target["password"].text, "p%41")
            }
        }
    }

    func testInvalidBatchLeavesPreviousSubscriptionIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeConfigurationStore(dataDirectory: directory)
        try await store.initializeRuntimeStore()
        let group = try await store.saveSubscription(.object(["remarks": .string("SIP008")]), id: nil)
        let server = #"{"server":"proxy.example","server_port":8388,"password":"pass","method":"aes-128-gcm"}"#
        try await store.replaceSubscription(group, rows: ShareLinkImport.decode("[" + server + "]"), serving: nil)
        let original = try await store.profileCatalog(group: group.id)
        XCTAssertEqual(original.count, 1)
        do {
            let rows = try ShareLinkImport.decode("[" + server + ",{}]")
            try await store.replaceSubscription(group, rows: rows, serving: nil)
            XCTFail("Partial subscription accepted")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_validation_failed") }
        let after = try await store.profileCatalog(group: group.id)
        XCTAssertEqual(after.map(\.id), original.map(\.id))
    }

    func testInvalidWireGuardReservedAndSIP008CipherAreRejectedBeforeSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let group = try await store.saveSubscription(.object(["remarks": .string("test")]), id: nil)
        let ss = #"{"server":"127.0.0.1","server_port":9,"method":"aes-128-gcm","password":"fixture"}"#
        try await store.replaceSubscription(group, rows: ShareLinkImport.decode("[\(ss)]"), serving: nil)
        let groups = try await store.subscriptions()
        let savedGroup = try XCTUnwrap(groups.first)
        let original = try await store.profileCatalog(group: group.id)
        let id = try XCTUnwrap(original.first?.id)
        let savedNode = try await store.profileDocument(id: id)
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let wg = "[Interface]\nPrivateKey=\(key)\n[Peer]\nPublicKey=\(key)\nEndpoint=127.0.0.1:9\nReserved="
        let changed = ss.replacingOccurrences(of: "fixture", with: "changed")
        let badSS = ss.replacingOccurrences(of: "aes-128-gcm", with: "not-a-cipher")
        let bad2022 = ss.replacingOccurrences(of: "aes-128-gcm", with: "2022-blake3-aes-128-gcm")
        for text in ["[\(changed),\(badSS)]", "[\(changed),\(bad2022)]", wg + "1,2", wg + "1,2,3,4", wg + "1,2,256",
                     wg.replacingOccurrences(of: "PrivateKey=" + key, with: "PrivateKey=!!!"),
                     wg.replacingOccurrences(of: "PublicKey=" + key, with: "PublicKey=AA=="),
                     wg + "\nPresharedKey=invalid"] {
            do {
                _ = try await store.importProfiles(content: text, groupID: group.id, isSubscription: false)
                XCTFail("Invalid manual import accepted")
            } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_validation_failed") }
            do {
                let rows = try ShareLinkImport.decode(text)
                try await store.replaceSubscription(savedGroup, rows: rows, serving: nil)
                XCTFail("Invalid subscription accepted")
            } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_validation_failed") }
            let after = try await store.profileCatalog(group: group.id)
            XCTAssertEqual(after.map(\.id), [id])
            let actual = try await store.profileDocument(id: id)
            XCTAssertEqual(actual, savedNode)
        }
        for reserved in ["", "0, 128, 255"] {
            let row = try XCTUnwrap(ShareLinkImport.decode(wg + reserved).first)
            let outbound = try XrayOutbound(node: NativeConfigurationStore.nodeDocument(from: row), config: .null).build()
            XCTAssertEqual(outbound["settings"]["reserved"].items.map(\.text), reserved.isEmpty ? [] : ["0","128","255"])
        }
    }

    func testShadowsocksAliasesAndGroupEligibilityUseTheSameCipherPolicy() throws {
        let methods = ["aes-128-gcm", "AEAD_AES_128_GCM", "AEAD_AES_256_GCM", "aes-256-gcm",
                       "chacha20-ietf-poly1305", "chacha20-poly1305", "aead_chacha20_poly1305",
                       "xchacha20-ietf-poly1305", "xchacha20-poly1305", "aead_xchacha20_poly1305",
                       "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"]
        for method in methods + ["none", "plain", "unknown"] {
            let length = method == "2022-blake3-aes-128-gcm" ? 16 : 32
            let password = method.hasPrefix("2022-") ? Data(repeating: 8, count: length).base64EncodedString() : "fixture"
            let input = #"[{"server":"127.0.0.1","server_port":9,"method":"\#(method)","password":"\#(password)"}]"#
            let row = try XCTUnwrap(ShareLinkImport.decode(input).first)
            let node = NativeConfigurationStore.nodeDocument(from: row)
            XCTAssertEqual(XrayProfileGraph.canJoinSubscriptionGroup(node), methods.contains(method), method)
            let outbound = try XrayOutbound(node: node, config: .null)
            if methods.contains(method) {
                XCTAssertEqual(try outbound.build()["settings"]["method"].text, method.lowercased())
            } else {
                XCTAssertThrowsError(try outbound.build())
            }
        }
    }

    func testSIP008IdentitySurvivesRenameLegacyAdoptionAndMissingID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let group = try await store.saveSubscription(.object(["remarks": .string("SIP008")]), id: nil)
        let provider = UUID().uuidString
        func replace(_ host: String, provider: String?, serving: String?) async throws {
            var server: SettingsValue = .object(["server": .string(host), "server_port": .number(8388),
                "password": .string("fixture"), "method": .string("aes-128-gcm")])
            if let provider { server["id"] = .string(provider) }
            let groups = try await store.subscriptions()
            try await store.replaceSubscription(XCTUnwrap(groups.first), rows: ShareLinkImport.decode(SettingsValue.array([server]).json()), serving: serving)
        }
        try await replace("old.invalid", provider: nil, serving: nil)
        let before = try await store.profileCatalog(group: group.id)
        let localID = try XCTUnwrap(before.first?.id)
        var settings = try await store.readSettings()
        settings["IndexId"] = .string(localID)
        try await store.writeSettings(settings)
        try await replace("old.invalid", provider: provider.lowercased(), serving: localID)
        try await replace("old.invalid", provider: nil, serving: localID)
        try await replace("new.invalid", provider: provider, serving: localID)
        let after = try await store.profileCatalog(group: group.id)
        XCTAssertEqual(after.map(\.id), [localID])
        XCTAssertEqual(after.first?.isCurrent, true)
        let current = try await store.profileDocument(id: localID)
        XCTAssertEqual(current["address"].text, "new.invalid")
    }

    func testConflictingOrDuplicateProviderIDsNeverOverrideEndpointEvidence() throws {
        func row(_ provider: UUID, _ host: String, local: String = "") throws -> RuntimeDatabase.Row {
            let input = #"[{"id":"\#(provider.uuidString)","server":"\#(host)","server_port":8388,"method":"aes-128-gcm","password":"p"}]"#
            var result = try XCTUnwrap(ShareLinkImport.decode(input).first)
            result["IndexId"] = .text(local)
            return result
        }
        let a = UUID(), b = UUID()
        let prior = [try row(a, "one.invalid", local: "one"), try row(a, "two.invalid", local: "two")]
        let matched = SubscriptionMatchIndex(previous: prior, incoming: [try row(a, "two.invalid"), try row(a, "one.invalid")])
        XCTAssertEqual(matched.matches.map { $0?["IndexId"] }, [.text("two"), .text("one")])
        let ambiguous = SubscriptionMatchIndex(previous: prior, incoming: [try row(a, "moved.invalid")])
        XCTAssertNil(ambiguous.matches[0])
        let replaced = SubscriptionMatchIndex(previous: [prior[0]], incoming: [try row(b, "one.invalid")])
        XCTAssertNil(replaced.matches[0])
    }

    func testShadowsocks2022PSKEncodingsMatchTheEmbeddedCore() {
        let aes128 = "2022-blake3-aes-128-gcm", aes256 = "2022-blake3-aes-256-gcm", cha = "2022-blake3-chacha20-poly1305"
        let k16 = Data(repeating: 7, count: 16).base64EncodedString(), k32 = Data(repeating: 7, count: 32).base64EncodedString()
        for (method, password) in [(aes128,k16), (aes128,k16 + ":" + k16), (aes128,String(repeating: "!", count: 16)),
                                   (aes256,k32), (cha,k32), ("aes-128-gcm","legacy text")] {
            XCTAssertTrue(XrayOutbound.acceptsShadowsocksPassword(password, method: method))
        }
        for (method, password) in [(aes128,k32), (aes256,k16), (aes128,k16 + ":"), (cha,k32 + ":" + k32),
                                   (aes128,String(repeating: "A", count: 16)), (aes128,"fixture")] {
            XCTAssertFalse(XrayOutbound.acceptsShadowsocksPassword(password, method: method))
        }
        let k = Data(repeating: 0xff, count: 32).base64EncodedString()
        let id = String(repeating: "ff", count: 32)
        for key in [id.uppercased(), k, String(k.dropLast()), k.replacingOccurrences(of: "/", with: "_")] {
            XCTAssertEqual(XrayOutbound.wireGuardKeyIdentity(key), id)
        }
        for key in ["!!!", k + "=", "_" + k.dropFirst(), "00", k16] { XCTAssertNil(XrayOutbound.wireGuardKeyIdentity(key)) }
    }

    func testWireGuardReorderedPeersKeepTheirSelectionAndTrafficWhenEndpointsChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let group = try await store.saveSubscription(.object(["remarks": .string("WireGuard")]), id: nil)
        let a = Data(repeating: 2, count: 32).base64EncodedString()
        let b = Data(repeating: 3, count: 32).base64EncodedString()
        let prefix = "[Interface]\nPrivateKey=" + Data(repeating: 1, count: 32).base64EncodedString()
        func peer(_ key: String, _ host: String) -> String { "\n[Peer]\nPublicKey=\(key)\nEndpoint=\(host):4000" }
        try await store.replaceSubscription(group, rows: ShareLinkImport.decode(prefix + peer(a, "a.invalid") + peer(b, "b.invalid")), serving: nil)
        let before = try await store.profileCatalog(group: group.id)
        let first = try XCTUnwrap(before.first { $0.remarks == "WireGuard Peer 1" })
        let second = try XCTUnwrap(before.first { $0.remarks == "WireGuard Peer 2" })
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ServerStatItem(IndexId,TotalDown) VALUES (?,12345)", [.text(first.id)])
        var settings = try await store.readSettings()
        settings["IndexId"] = .string(first.id)
        try await store.writeSettings(settings)
        let current = try await store.subscriptions()
        let rotated = prefix + peer(b, "new-b.invalid") + peer(String(repeating: "02", count: 32), "new-a.invalid")
        try await store.replaceSubscription(XCTUnwrap(current.first), rows: ShareLinkImport.decode(rotated), serving: first.id)
        let after = try await store.profileCatalog(group: group.id)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.first { $0.isCurrent }?.id, first.id)
        let docA = try await store.profileDocument(id: first.id), docB = try await store.profileDocument(id: second.id)
        XCTAssertEqual(docA["address"].text, "new-a.invalid")
        XCTAssertEqual(docB["address"].text, "new-b.invalid")
        XCTAssertEqual(try db.query("SELECT p.Address FROM ProfileItem p JOIN ServerStatItem s ON p.IndexId=s.IndexId WHERE s.TotalDown=12345"),
                       [["Address": .text("new-a.invalid")]])
    }

    func testAmbiguousOrReplacedWireGuardKeysDoNotInheritIDsByName() throws {
        func row(_ label: String, _ host: String, _ byte: UInt8) throws -> RuntimeDatabase.Row {
            let publicKey = Data(repeating: byte, count: 32).base64EncodedString()
            let extra = try SettingsValue.object(["WgPublicKey": .string(publicKey)]).json()
            return ["ConfigType": .integer(9), "Address": .text(host), "Port": .integer(9), "Remarks": .text(label), "ProtoExtra": .text(extra)]
        }
        let a = try row("first", "one.invalid", 1), b = try row("second", "two.invalid", 1)
        let ambiguous = try [row("first", "three.invalid", 1), row("second", "four.invalid", 1)]
        XCTAssertTrue(SubscriptionMatchIndex(previous: [a,b], incoming: ambiguous).matches.allSatisfy { $0 == nil })
        XCTAssertNil(try SubscriptionMatchIndex(previous: [a], incoming: [row("first", "one.invalid", 2)]).matches[0])
        let sameEndpoints = try [row("first", "two.invalid", 1), row("second", "one.invalid", 1)]
        XCTAssertEqual(SubscriptionMatchIndex(previous: [a,b], incoming: sameEndpoints).matches, [b,a])
    }

    func testWireGuardPeersProduceIndependentOutbounds() throws {
        let keys = (1...4).map { Data(repeating: UInt8($0), count: 32).base64EncodedString() }
        let input = """
        # fixture
        [Interface]
        PrivateKey = \(keys[0])
        Address = 10.0.0.2/32, fd00::2/128 ; interface
        MTU = 1420
        DNS = 2001:db8::53, 1.2.3.4
        [Peer]
        PublicKey = \(keys[1])
        PresharedKey = \(keys[2])
        Reserved = 1, 2, 3 # padding
        Endpoint = [2001:db8::1]:51820 # endpoint
        AllowedIPs = 10.0.0.0/8
        PersistentKeepalive = 25
        [Peer]
        PublicKey = \(keys[3])
        Endpoint = example.com:12345
        """
        let rows = try ShareLinkImport.decode(input.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(rows.count, 2)
        let outbounds = try rows.map { try XrayOutbound(node: NativeConfigurationStore.nodeDocument(from: $0), config: .object([:])).build()["settings"] }
        let first = try XCTUnwrap(outbounds[0]["peers"].items.first)
        XCTAssertEqual(first["endpoint"].text, "[2001:db8::1]:51820")
        XCTAssertEqual(first["publicKey"].text, keys[1])
        XCTAssertEqual(first["preSharedKey"].text, keys[2])
        XCTAssertEqual(first["allowedIPs"].items.map(\.text), ["10.0.0.0/8"])
        XCTAssertEqual(first["keepAlive"].text, "25")
        XCTAssertEqual(outbounds[0]["reserved"].items.map(\.text), ["1","2","3"])
        let second = try XCTUnwrap(outbounds[1]["peers"].items.first)
        XCTAssertEqual(second["endpoint"].text, "example.com:12345")
        XCTAssertEqual(second["preSharedKey"], .null)
        for settings in outbounds {
            XCTAssertEqual(settings["secretKey"].text, keys[0])
            XCTAssertEqual(settings["mtu"].text, "1420")
            XCTAssertEqual(settings["address"].items.map(\.text), ["10.0.0.2/32","fd00::2/128"])
            XCTAssertEqual(settings["remoteDNS"].items.map(\.text), ["2001:db8::53","1.2.3.4"])
        }
        XCTAssertThrowsError(try ShareLinkImport.decode(input.replacingOccurrences(of: "example.com:12345", with: "example.com:9999999999999999999999999")))
        XCTAssertThrowsError(try ShareLinkImport.decode(input + "\n[Peer]\nPublicKey=bad"))
    }

    func testShareValuesDecodeExactlyOnceAndKeepLiteralEquals() throws {
        for (encoded, decoded) in [("p%2541ss","p%41ss"), ("p%25ss","p%ss"), ("a%3Ab%2Fc%2B%3D","a:b/c+=")] {
            let node = try XCTUnwrap(ShareLinkImport.decode("ss://2022-blake3-aes-128-gcm:" + encoded + "@example.com:8388").first)
            XCTAssertEqual(node["Password"], .text(decoded))
        }
        for encoded in ["ob%2541fs", "66%25ff", "100%25"] {
            let row = try XCTUnwrap(ShareLinkImport.decode("hy2://pw@example.com:443/?obfs=salamander&obfs-password=" + encoded).first)
            let node = NativeConfigurationStore.nodeDocument(from: row)
            let link = try XCTUnwrap(ProfileTransfer.share(node))
            let imported = NativeConfigurationStore.nodeDocument(from: try XCTUnwrap(ShareLinkImport.decode(link).first))
            XCTAssertEqual(try SettingsValue.parse(imported["protoExtra"].text)["SalamanderPass"].text, encoded.removingPercentEncoding)
        }
        for ech in ["AAj+DQAEAAAAAA==", "AAj%2BDQAEAAAAAA%3D%3D"] {
            let row = try XCTUnwrap(ShareLinkImport.decode("hy2://pw@example.com:443/?ech=" + ech + "&obfs-password=a%20b").first)
            XCTAssertEqual(row["EchConfigList"], .text("AAj+DQAEAAAAAA=="))
            let node = NativeConfigurationStore.nodeDocument(from: row)
            XCTAssertEqual(try SettingsValue.parse(node["protoExtra"].text)["SalamanderPass"].text, "a b")
        }
        let ss = try XCTUnwrap(ShareLinkImport.decode("ss://YWVzLTEyOC1nY206cGFzcw==@example.com:8388/?plugin=obfs-local;obfs=http;obfs-host=obfs.example").first)
        let node = NativeConfigurationStore.nodeDocument(from: ss)
        XCTAssertEqual(try SettingsValue.parse(node["transportExtra"].text)["Host"].text, "obfs.example")
    }
}
