import XCTest
@testable import TunShared
import Darwin

final class TrustedCoreStoreTests: XCTestCase {
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func seed(_ root: URL, _ token: String, _ data: Data) throws {
        let kind = root.appendingPathComponent("xray")
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = kind.appendingPathComponent("stage-" + token)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifest: [String: Any] = ["kind": "xray", "token": token, "releaseURL": "official-fixture", "packageSHA256": "fixture",
            "executableSHA256": OfficialCorePolicy.hash(data), "version": "Xray 1.0.0", "committed": false]
        try data.write(to: stage.appendingPathComponent("core"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.appendingPathComponent("core").path)
        try JSONSerialization.data(withJSONObject: manifest).write(to: stage.appendingPathComponent("manifest.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent("manifest.json").path)
    }
    func testOnlyFixedOfficialRepositoriesAndHostArchitectureAreAccepted() throws {
        let good = "https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-macos-arm64-v8a.zip"
        #if arch(arm64)
        XCTAssertNoThrow(try OfficialCorePolicy.coordinates(kind: "xray", releaseURL: good))
        #endif
        for bad in [good.replacingOccurrences(of: "github.com", with: "github.com.evil.example"), good.replacingOccurrences(of: "XTLS", with: "attacker"),
                    good + "?redirect=evil", good.replacingOccurrences(of: "https://", with: "http://"),
                    good.replacingOccurrences(of: "v26.3.27", with: "..%2f.."), good.replacingOccurrences(of: "arm64-v8a", with: "arm32-v7a")] {
            XCTAssertThrowsError(try OfficialCorePolicy.coordinates(kind: "xray", releaseURL: bad))
        }
        XCTAssertThrowsError(try OfficialCorePolicy.coordinates(kind: "mihomo", releaseURL: good))
    }
    func testOfficialDigestIsRequiredAndTamperedPackagesAreRejected() throws {
        let data = Data("approved-package".utf8), url = "https://github.com/XTLS/Xray-core/releases/download/v1/x.zip"
        func release(_ digest: String?) throws -> OfficialCoreRelease {
            let value: [String: Any] = ["draft": false, "assets": [["name": "x.zip", "size": data.count,
                "state": "uploaded", "digest": digest as Any? ?? NSNull(), "browser_download_url": url]]]
            return try JSONDecoder().decode(OfficialCoreRelease.self, from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertEqual(try OfficialCorePolicy.verifiedDigest(release: release("sha256:" + OfficialCorePolicy.hash(data)), name: "x.zip", releaseURL: url, archive: data), OfficialCorePolicy.hash(data))
        XCTAssertThrowsError(try OfficialCorePolicy.verifiedDigest(release: release(nil), name: "x.zip", releaseURL: url, archive: data))
        XCTAssertThrowsError(try OfficialCorePolicy.verifiedDigest(release: release("sha256:" + String(repeating: "0", count: 64)), name: "x.zip", releaseURL: url, archive: data))
    }
    func testFailedRestartRestoresThePreviousVerifiedSelection() throws {
        let root = try root(), store = TrustedCoreStore(root: root, owner: getuid())
        let a = UUID().uuidString, b = UUID().uuidString
        try seed(root, a, Data("old".utf8)); _ = try store.transition(action: "update-activate", kind: "xray", token: a)
        _ = try store.transition(action: "update-finish", kind: "xray", token: a)
        try seed(root, b, Data("new".utf8)); _ = try store.transition(action: "update-activate", kind: "xray", token: b)
        XCTAssertEqual(try Data(contentsOf: store.source("xray")!.url), Data("new".utf8))
        _ = try store.transition(action: "update-rollback", kind: "xray", token: b)
        XCTAssertEqual(try Data(contentsOf: store.source("xray")!.url), Data("old".utf8))
    }
    func testSuccessfulCommitRemovesOldVersionAndSurvivesHelperRestart() throws {
        let root = try root(), store = TrustedCoreStore(root: root, owner: getuid())
        for value in ["old", "new"] {
            let token = UUID().uuidString; try seed(root, token, Data(value.utf8))
            _ = try store.transition(action: "update-activate", kind: "xray", token: token)
            _ = try store.transition(action: "update-finish", kind: "xray", token: token)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("xray/previous").path))
        XCTAssertEqual(try Data(contentsOf: TrustedCoreStore(root: root, owner: getuid()).source("xray")!.url), Data("new".utf8))
    }
    func testInterruptedActivationRecoversOldVersionAfterHelperRestart() throws {
        let root = try root(), store = TrustedCoreStore(root: root, owner: getuid())
        let a = UUID().uuidString, b = UUID().uuidString
        try seed(root, a, Data("old".utf8)); _ = try store.transition(action: "update-activate", kind: "xray", token: a)
        _ = try store.transition(action: "update-finish", kind: "xray", token: a)
        try seed(root, b, Data("new".utf8)); _ = try store.transition(action: "update-activate", kind: "xray", token: b)
        let restarted = TrustedCoreStore(root: root, owner: getuid())
        XCTAssertEqual(try Data(contentsOf: restarted.source("xray")!.url), Data("old".utf8))
        XCTAssertNoThrow(try restarted.transition(action: "update-rollback", kind: "xray", token: b))
    }
    func testStoredExecutableTamperingAndSymlinkStoreAreRejected() throws {
        let root = try root(), store = TrustedCoreStore(root: root, owner: getuid()), token = UUID().uuidString
        try seed(root, token, Data("original".utf8)); _ = try store.transition(action: "update-activate", kind: "xray", token: token)
        try Data("tampered".utf8).write(to: root.appendingPathComponent("xray/current/core"))
        XCTAssertThrowsError(try store.source("xray"))
        let link = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try TrustedCoreStore(root: link, owner: getuid()).source("xray"))
        XCTAssertThrowsError(try store.transition(action: "update-discard", kind: "xray", token: "../../current"))
    }
}
