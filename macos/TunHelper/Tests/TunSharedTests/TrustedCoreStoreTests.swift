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
    private func seed(_ root: URL, _ token: String, _ data: Data, version: String = "Xray 1.0.0") throws {
        let kind = root.appendingPathComponent("xray")
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = kind.appendingPathComponent("stage-" + token)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifest: [String: Any] = ["kind": "xray", "token": token, "releaseURL": "official-fixture", "packageSHA256": "fixture",
            "executableSHA256": OfficialCorePolicy.hash(data), "version": version, "committed": false]
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
    func testAffectedVerifiedCacheDefersToSignedBundleButTamperingStillFails() throws {
        let root = try root(), store = TrustedCoreStore(root: root, owner: getuid()), token = UUID().uuidString
        try seed(root, token, Data("affected".utf8), version: "Xray 26.10.21 (Xray) 1b1647c")
        _ = try store.transition(action: "update-activate", kind: "xray", token: token)
        _ = try store.transition(action: "update-finish", kind: "xray", token: token)
        XCTAssertNil(try store.source("xray"))
        XCTAssertTrue(OfficialCorePolicy.hasKnownDarwinBindingBug("Xray 26.10.21 (Xray) 1b1647c"))
        XCTAssertFalse(OfficialCorePolicy.hasKnownDarwinBindingBug("Xray 26.10.21 (Xray) 1b1647c-v2raym-darwin-bind1"))
        XCTAssertFalse(OfficialCorePolicy.hasKnownDarwinBindingBug("Xray 26.10.21 (Xray) 1b1647c-v2raym-darwin-bind2"))
        XCTAssertTrue(OfficialCorePolicy.hasKnownDarwinBindingBug("Xray 26.10.21 (Xray) 1b1647c-v2raym-darwin-bind20"))
        try Data("tampered".utf8).write(to: root.appendingPathComponent("xray/current/core"))
        XCTAssertThrowsError(try store.source("xray"))
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
    func testCrashBetweenActivationRenamesRestoresPreviousAndAllowsNextUpdate() throws {
        let root = try root(), store = TrustedCoreStore(root: root, owner: getuid())
        let a = UUID().uuidString, b = UUID().uuidString
        try seed(root, a, Data("old".utf8))
        _ = try store.transition(action: "update-activate", kind: "xray", token: a)
        _ = try store.transition(action: "update-finish", kind: "xray", token: a)
        try FileManager.default.moveItem(at: root.appendingPathComponent("xray/current"), to: root.appendingPathComponent("xray/previous"))
        let restarted = TrustedCoreStore(root: root, owner: getuid())
        XCTAssertNotNil(try restarted.source("xray"))
        try seed(root, b, Data("new".utf8))
        XCTAssertNoThrow(try restarted.transition(action: "update-activate", kind: "xray", token: b))
    }
    func testCrashAfterCommittedManifestBeforePreviousDeletionFinishesCleanup() throws {
        let root = try root(), store = TrustedCoreStore(root: root, owner: getuid())
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString
        try seed(root, a, Data("old".utf8))
        _ = try store.transition(action: "update-activate", kind: "xray", token: a)
        _ = try store.transition(action: "update-finish", kind: "xray", token: a)
        try seed(root, b, Data("new".utf8))
        _ = try store.transition(action: "update-activate", kind: "xray", token: b)
        let manifestURL = root.appendingPathComponent("xray/current/manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["committed"] = true
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let restarted = TrustedCoreStore(root: root, owner: getuid())
        XCTAssertNotNil(try restarted.source("xray"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("xray/previous").path))
        try seed(root, c, Data("next".utf8))
        XCTAssertNoThrow(try restarted.transition(action: "update-activate", kind: "xray", token: c))
    }

    private var assetName: String {
        #if arch(arm64)
        return "Xray-macos-arm64-v8a.zip"
        #else
        return "Xray-macos-64.zip"
        #endif
    }
    private var releaseURL: String { "https://github.com/XTLS/Xray-core/releases/download/v1/" + assetName }
    private func releaseFixture(_ archive: Data) throws -> OfficialCoreRelease {
        let object: [String: Any] = ["draft": false, "assets": [["name": assetName, "size": archive.count,
            "state": "uploaded", "digest": "sha256:" + OfficialCorePolicy.hash(archive), "browser_download_url": releaseURL]]]
        return try JSONDecoder().decode(OfficialCoreRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testSlowStageDoesNotBlockRollbackAndCancelledMetadataCreatesNoStage() throws {
        let root = try root(), archive = Data("archive".utf8), release = try releaseFixture(archive)
        let entered = expectation(description: "metadata entered"), finished = expectation(description: "stage cancelled")
        let releaseMetadata = DispatchSemaphore(value: 0), cancellation = HelperCancellation()
        let store = TrustedCoreStore(root: root, owner: getuid(), metadataLoader: { _, _, context in
            entered.fulfill()
            _ = releaseMetadata.wait(timeout: .now() + 3)
            try context.check()
            return release
        }, toolRunner: nil)
        let a = UUID().uuidString, b = UUID().uuidString
        try seed(root, a, Data("old".utf8)); _ = try store.transition(action: "update-activate", kind: "xray", token: a)
        _ = try store.transition(action: "update-finish", kind: "xray", token: a)
        try seed(root, b, Data("new".utf8)); _ = try store.transition(action: "update-activate", kind: "xray", token: b)
        let url = releaseURL
        DispatchQueue.global().async {
            do {
                _ = try store.stage(kind: "xray", releaseURL: url, archive: archive,
                                    context: HelperOperationContext(cancellation: cancellation))
                XCTFail("cancelled stage succeeded")
            } catch { XCTAssertEqual((error as? HelperFailure)?.description, "update_cancelled") }
            finished.fulfill()
        }
        wait(for: [entered], timeout: 2)
        let rolledBack = expectation(description: "rollback did not wait for metadata")
        DispatchQueue.global().async {
            do { _ = try store.transition(action: "update-rollback", kind: "xray", token: b) }
            catch { XCTFail("rollback failed: \(error)") }
            rolledBack.fulfill()
        }
        wait(for: [rolledBack], timeout: 1)
        cancellation.cancel(); releaseMetadata.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: store.source("xray")!.url), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("xray").path), ["current"])
    }
    func testCancellationDuringToolRemovesPrivateStage() throws {
        let root = try root(), archive = Data("archive".utf8), release = try releaseFixture(archive)
        let cancellation = HelperCancellation()
        let store = TrustedCoreStore(root: root, owner: getuid(), metadataLoader: { _, _, _ in release },
                                    toolRunner: { _, _, _, context in
            cancellation.cancel()
            try context.check()
            return Data()
        })
        XCTAssertThrowsError(try store.stage(kind: "xray", releaseURL: releaseURL, archive: archive,
                                            context: HelperOperationContext(cancellation: cancellation))) {
            XCTAssertEqual(($0 as? HelperFailure)?.description, "update_cancelled")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("xray").path), [])
    }
    func testStageDeadlineExpiresBeforeNetworkOrToolWork() throws {
        let root = try root()
        let store = TrustedCoreStore(root: root, owner: getuid(), metadataLoader: { _, _, _ in
            XCTFail("expired operation reached network")
            throw HelperFailure("unexpected_network")
        }, toolRunner: nil)
        XCTAssertThrowsError(try store.stage(kind: "xray", releaseURL: releaseURL, archive: Data("archive".utf8),
                                            context: HelperOperationContext(timeout: 0))) {
            XCTAssertEqual(($0 as? HelperFailure)?.description, "update_timeout")
        }
        XCTAssertGreaterThan(HelperOperationContext.stageClientTimeout, HelperOperationContext.stageTimeout)
    }
    func testCancellationKillsAndReapsBlockedToolWithoutNetworking() throws {
        let store = TrustedCoreStore(root: try root(), owner: getuid()), cancellation = HelperCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancellation.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try store.tool("/bin/sleep", ["30"], context: HelperOperationContext(cancellation: cancellation))) {
            XCTAssertEqual(($0 as? HelperFailure)?.description, "update_cancelled")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testSharedDeadlineKillsAndReapsBlockedToolWithoutNetworking() throws {
        let store = TrustedCoreStore(root: try root(), owner: getuid())
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try store.tool("/bin/sleep", ["30"], context: HelperOperationContext(timeout: 0.05))) {
            XCTAssertEqual(($0 as? HelperFailure)?.description, "update_timeout")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testUncommittedFirstActivationCannotBeReplacedByConcurrentUpdate() throws {
        let root = try root(), store = TrustedCoreStore(root: root, owner: getuid())
        let a = UUID().uuidString, b = UUID().uuidString
        try seed(root, a, Data("first".utf8)); try seed(root, b, Data("second".utf8))
        _ = try store.transition(action: "update-activate", kind: "xray", token: a)
        XCTAssertThrowsError(try store.transition(action: "update-activate", kind: "xray", token: b)) {
            XCTAssertEqual(($0 as? HelperFailure)?.description, "update_store_busy")
        }
        XCTAssertEqual(try Data(contentsOf: store.source("xray")!.url), Data("first".utf8))
    }

}
