import Foundation
import XCTest
@testable import V2rayMKit

final class FileProfileTransferTests: XCTestCase {
    func testFileBackedProfilesExportAndRestoreFromStandaloneArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let raw = #"{"tag":"custom-egress","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":33127}]},"opaque":{"preserve":true}}"#
        let full = #"{"remarks":"full fixture","inbounds":[],"outbounds":["# + raw + "]}"
        let input = "[" + full + "," + raw + "]"
        let count = try await store.importProfiles(content: input, groupID: "", isSubscription: false)
        XCTAssertEqual(count, 2)
        let nodes = try await store.profileCatalog()
        let outbound = try XCTUnwrap(nodes.first { $0.remarks == "socks_custom-egress" })
        let complete = try XCTUnwrap(nodes.first { $0.remarks == "full fixture" })
        let document = try await store.profileDocument(id: outbound.id)
        XCTAssertTrue(document["address"].text.hasPrefix("v2raym-import-"))
        let generated = try await store.generateXrayConfiguration(nodeID: complete.id, metricsPort: nil)
        XCTAssertEqual(generated, try SettingsValue.parse(full))
        let transfer = try await store.exportProfiles(.object(["profileIds": .array([.string(outbound.id)]),
            "includeShareUris": .bool(false), "includeInnerUri": .bool(true), "includeClientConfig": .bool(false)]), metricsPort: 29123)
        let uri = try XCTUnwrap(transfer.first)["content"].text
        let parts = try XCTUnwrap(URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)))
        let encoded = try SettingsValue.parse(XCTUnwrap(ShareLinkImport.base64Text(String(parts.path.dropFirst()))))
        XCTAssertEqual(encoded["CustomOutboundObj"], try SettingsValue.parse(raw))
        XCTAssertEqual(encoded["Address"], .null)

        let scratch = root.appendingPathComponent("backup"), archive = root.appendingPathComponent("copy.zip")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try await store.createBackup(in: scratch, at: archive)
        let restoredRoot = root.appendingPathComponent("restored")
        // Extract the actual backup using the same reader as the restore service.
        let configs = restoredRoot.appendingPathComponent("guiConfigs")
        try NativeBackupArchive.extract(archive, to: configs)
        let restored = NativeConfigurationStore(dataDirectory: restoredRoot)
        try await restored.initializeRuntimeStore()
        let rebuilt = try await restored.generateXrayConfiguration(nodeID: complete.id, metricsPort: nil)
        XCTAssertEqual(rebuilt, generated)
        let n = try await restored.importProfiles(content: uri, groupID: "", isSubscription: false)
        XCTAssertEqual(n, 1)
        _ = try await restored.removeProfiles([outbound.id], subscription: nil)
        let copies = try await restored.profileCatalog()
        let copy = try XCTUnwrap(copies.first { $0.remarks == outbound.remarks })
        let output = try await restored.generateXrayConfiguration(nodeID: copy.id, metricsPort: nil)
        XCTAssertEqual(output["outbounds"].items.first?["opaque"]["preserve"], .bool(true))
    }

    func testExternalFileAddressCannotBeImportedViaInnerURI() throws {
        let input: SettingsValue = .object(["ConfigVersion": .number(4), "ConfigType": .number(13), "CoreType": .number(2),
                                           "Address": .string("/tmp/external"), "Remarks": .string("fixture")])
        let link = "v2rayn://outbound/" + ProfileTransfer.base64URL(try JSONEncoder().encode(input))
        XCTAssertThrowsError(try ShareLinkImport.decode(link))
    }
}
