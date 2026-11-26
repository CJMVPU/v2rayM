import XCTest
@testable import V2rayMKit

final class NativeBackupTests: XCTestCase {
    func testWebDAVCheckVerifiesReadbackAndCleansNestedProbe() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let serverRoot = storage.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let script = try XCTUnwrap(Bundle.module.url(forResource: "webdav-server", withExtension: "py", subdirectory: "Fixtures"))
        let peer = Process(), input = Pipe(), output = Pipe()
        peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        peer.arguments = [script.path, serverRoot.path]
        peer.standardInput = input
        peer.standardOutput = output
        try peer.run()
        defer { try? input.fileHandleForWriting.close(); peer.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let host = NativeRuntimeHost(dataDirectory: storage.appendingPathComponent("app"), mayContactHelper: false, automaticMaintenance: false)
        let api = try await host.startClient()
        for scenario in ["ok", "shared", "denied", "corrupt"] {
            let base = serverRoot.appendingPathComponent(scenario)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
            if scenario == "shared" {
                try FileManager.default.createDirectory(at: base.appendingPathComponent("team/backup"), withIntermediateDirectories: true)
            }
            let settings: SettingsValue = .object(["url": .string("http://127.0.0.1:\(port)/\(scenario)"),
                                                  "dirName": .string("team/backup"), "userName": .string("test"),
                                                  "password": .string("test")])
            try await api.send("/api/settings/webdav", method: "PUT", body: settings)
            do {
                try await api.perform("/api/backup/webdav/check")
                XCTAssertTrue(["ok", "shared"].contains(scenario), "unreadable or corrupted data passed verification")
            } catch let failure as ClientFailure {
                XCTAssertTrue(["denied", "corrupt"].contains(scenario))
                XCTAssertEqual(failure.code, "webdav_transfer_failed")
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("team/backup").path)
            XCTAssertTrue(files.isEmpty, "probe left a file after \(scenario)")
        }
        try await host.stop()
    }

    private func oldBackup() throws -> Data {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "legacy-backup", withExtension: "zip", subdirectory: "Fixtures"))
        return try Data(contentsOf: file)
    }

    func testNativeHostRestoresOldBackendArchiveAndItsOwnBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = NativeRuntimeHost(dataDirectory: root, mayContactHelper: false, automaticMaintenance: false)
        let api = try await host.startClient()
        let fresh = try await api.encodedResponse("/api/backup/download", method: "GET", body: nil)
        let restored = try await api.encodedResponse("/api/backup/restore", method: "POST", body: oldBackup())
        let safety = try JSONDecoder().decode(SettingsValue.self, from: restored)["data"]["safetyBackup"].text
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("guiBackups/" + safety).path))
        let nodes = try await api.profileMetadata()
        XCTAssertEqual(Set(nodes.map(\.id)), Set(["legacy", "trojan", "socks"]))
        let live = try await api.encodedResponse("/api/backup/download", method: "GET", body: nil)
        do {
            _ = try await api.encodedResponse("/api/backup/restore", method: "POST", body: live.prefix(20))
            XCTFail("Truncated archive accepted")
        } catch let e as ClientFailure { XCTAssertEqual(e.code, "backup_archive_invalid") }
        let retained = try await api.profileMetadata()
        XCTAssertEqual(retained.map(\.id), nodes.map(\.id))
        _ = try await api.encodedResponse("/api/backup/restore", method: "POST", body: fresh)
        let empty = try await api.profileMetadata()
        XCTAssertTrue(empty.isEmpty)
        _ = try await api.encodedResponse("/api/backup/restore", method: "POST", body: live)
        try await host.stop()
        let another = NativeRuntimeHost(dataDirectory: root, mayContactHelper: false, automaticMaintenance: false)
        let reopened = try await another.startClient()
        let persisted = try await reopened.profileMetadata()
        XCTAssertEqual(persisted.map(\.id), nodes.map(\.id))
        try await another.stop()
    }

    func testExternalWALRestoreIncludesCommittedPagesAndRejectsDamagedTail() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let input = root.appendingPathComponent("source/guiConfigs")
        try fm.createDirectory(at: input, withIntermediateDirectories: true)
        let database = input.appendingPathComponent("guiNDB.db")
        let wal = input.appendingPathComponent("guiNDB.db-wal")
        let db = try RuntimeDatabase(url: database, writable: true, create: true)
        defer { withExtendedLifetime(db) {} }
        _ = try db.query("PRAGMA journal_mode=WAL")
        _ = try db.query("PRAGMA wal_autocheckpoint=0")
        _ = try db.query("CREATE TABLE ProfileItem(IndexId varchar PRIMARY KEY NOT NULL, Remarks varchar, ConfigType integer)")
        _ = try db.query("INSERT INTO ProfileItem VALUES ('checkpoint','checkpoint',4)")
        _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
        _ = try db.query("INSERT INTO ProfileItem VALUES ('recent','recent',4)")
        try Data("{}".utf8).write(to: input.appendingPathComponent("guiNConfig.json"))
        let files = root.appendingPathComponent("fixture/guiConfigs")
        try fm.createDirectory(at: files.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: input, to: files)
        var journal = try Data(contentsOf: wal)
        func archive(_ name: String) throws -> Data {
            let zip = root.appendingPathComponent(name + ".zip")
            let task = Process()
            task.currentDirectoryURL = files.deletingLastPathComponent()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            task.arguments = ["-q", "-0", zip.path, "guiConfigs/guiNDB.db", "guiConfigs/guiNDB.db-wal", "guiConfigs/guiNConfig.json"]
            try task.run(); task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0)
            return try Data(contentsOf: zip)
        }

        let host = NativeRuntimeHost(dataDirectory: root.appendingPathComponent("live"), mayContactHelper: false, automaticMaintenance: false)
        let api = try await host.startClient()
        _ = try await api.encodedResponse("/api/backup/restore", method: "POST", body: archive("complete"))
        let good = try await api.profileMetadata()
        XCTAssertEqual(Set(good.map(\.id)), ["checkpoint","recent"])

        journal[journal.count - 1] ^= 1
        try journal.write(to: files.appendingPathComponent("guiNDB.db-wal"))
        do {
            _ = try await api.encodedResponse("/api/backup/restore", method: "POST", body: archive("damaged"))
            XCTFail("A damaged commit must not be treated as a valid older checkpoint")
        } catch let e as ClientFailure { XCTAssertEqual(e.code, "backup_database_incompatible") }
        let retained = try await api.profileMetadata()
        XCTAssertEqual(Set(retained.map(\.id)), ["checkpoint","recent"])
        try await host.stop()
    }

    func testRestoreJournalSurvivesExitImmediatelyBeforeOrAfterDirectorySwap() async throws {
        for afterSwap in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = NativeConfigurationStore(dataDirectory: root)
            try await source.initializeRuntimeStore()
            let oldData = Data("keep existing local history".utf8)
            let local = root.appendingPathComponent("guiConfigs/unknown-local-file.txt")
            try oldData.write(to: local)
            let tx = NativeBackupRestore(data: root)
            let zip = root.appendingPathComponent("input.zip")
            try oldBackup().write(to: zip)
            try tx.prepare(zip)
            try tx.buildCandidate()
            let intent = NativeBackupRestore.Intent(id: UUID(), runningNode: nil)
            try tx.begin(intent)
            if afterSwap { try tx.activate(intent) }
            let new = NativeRuntimeHost(dataDirectory: root, mayContactHelper: false, automaticMaintenance: false)
            let api = try await new.startClient()
            let oldNodes = try await api.profileMetadata()
            XCTAssertTrue(oldNodes.isEmpty)
            XCTAssertEqual(try Data(contentsOf: local), oldData)
            XCTAssertNil(try tx.readIntent())
            XCTAssertFalse(FileManager.default.fileExists(atPath: tx.staging.path))
            try await new.stop()
        }
    }

    func testPortableBackupRestoresNestedAndAbsoluteProfilesAcrossDirectories() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = NativeConfigurationStore(dataDirectory: root)
        try await source.initializeRuntimeStore()
        let directory = root.appendingPathComponent("guiConfigs")
        let db = try RuntimeDatabase(url: directory.appendingPathComponent("guiNDB.db"), writable: true)
        let insert = "INSERT INTO ProfileItem(IndexId,ConfigVersion,ConfigType,CoreType,Address) VALUES(?,4,?,2,?)"
        let complete = Data(#"{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}"#.utf8)
        let outbound = Data(#"{"protocol":"freedom","tag":"local"}"#.utf8)
        let first = directory.appendingPathComponent("first/old.json")
        let second = directory.appendingPathComponent("second/old.json")
        for (file, data) in [(first, complete), (second, outbound)] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        for (id, type, path) in [("full", 2, "first/old.json"), ("duplicate", 2, first.path), ("out", 13, second.path)] {
            _ = try db.query(insert, [.text(id), .integer(Int64(type)), .text(path)])
        }
        let zip = root.appendingPathComponent("portable.zip")
        try await source.createBackup(in: root.appendingPathComponent("scratch"), at: zip)
        XCTAssertEqual(try db.query("SELECT Address FROM ProfileItem WHERE IndexId='full'").first?["Address"], .text("first/old.json"))
        try fm.removeItem(at: first)
        try fm.removeItem(at: second)
        let restoredRoot = root.appendingPathComponent("clean")
        let host = NativeRuntimeHost(dataDirectory: restoredRoot, mayContactHelper: false, automaticMaintenance: false)
        let api = try await host.startClient()
        _ = try await api.encodedResponse("/api/backup/restore", method: "POST", body: Data(contentsOf: zip))
        let restored = NativeConfigurationStore(dataDirectory: restoredRoot)
        let files = try fm.contentsOfDirectory(atPath: restoredRoot.appendingPathComponent("guiConfigs").path)
        XCTAssertEqual(files.filter { $0.hasPrefix("v2raym-import-") }.count, 2)
        for id in ["full", "duplicate"] {
            let generated = try await restored.generateXrayConfiguration(nodeID: id, metricsPort: nil)
            XCTAssertEqual(generated["outbounds"].items.first?["protocol"], .string("freedom"))
        }
        let profile = try await restored.profileDocument(id: "out")
        let path = restoredRoot.appendingPathComponent("guiConfigs").appendingPathComponent(profile["address"].text)
        XCTAssertEqual(try Data(contentsOf: path), outbound)
        let generated = try await restored.generateXrayConfiguration(nodeID: "out", metricsPort: nil)
        XCTAssertEqual(generated["outbounds"].items.first?["protocol"], .string("freedom"))
        try await host.stop()
    }

    func testPortableBackupRejectsMissingAndExternalReferencesWithoutBlockingLocalRollback() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let dir = root.appendingPathComponent("guiConfigs")
        let db = try RuntimeDatabase(url: dir.appendingPathComponent("guiNDB.db"), writable: true)
        let external = root.appendingPathComponent("external.json")
        try Data("private".utf8).write(to: external)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("alias.json"), withDestinationURL: external)
        _ = try db.query("INSERT INTO ProfileItem(IndexId,ConfigType,CoreType) VALUES('old',2,2)")
        for (path, code) in [("missing.json", "backup_profile_file_missing"), ("alias.json", "backup_profile_file_external")] {
            _ = try db.query("UPDATE ProfileItem SET Address=?", [.text(path)])
            let zip = root.appendingPathComponent("portable.zip")
            do {
                try await store.createBackup(in: root.appendingPathComponent("scratch"), at: zip)
                XCTFail("unexpected portable archive for " + path)
            } catch let e as ClientFailure { XCTAssertEqual(e.code, code) }
            XCTAssertFalse(fm.fileExists(atPath: zip.path))
        }
        try await store.createBackup(in: root.appendingPathComponent("scratch"), at: root.appendingPathComponent("local.zip"), forLocalRollback: true)
    }

    func testSnapshotIncludesCommittedWALAndExcludesAuthAndJournals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let dir = root.appendingPathComponent("guiConfigs")
        let db = try RuntimeDatabase(url: dir.appendingPathComponent("guiNDB.db"), writable: true)
        _ = try db.query("PRAGMA journal_mode=WAL")
        _ = try db.query("CREATE TABLE FutureData (Value TEXT)")
        _ = try db.query("INSERT INTO FutureData VALUES ('uncheckpointed')")
        for name in ["WebAPI-auth.json", "native-pending-edit.json"] { try Data("private".utf8).write(to: dir.appendingPathComponent(name)) }
        let zip = root.appendingPathComponent("backup.zip")
        try await store.createBackup(in: root.appendingPathComponent("snapshot"), at: zip)
        let dest = root.appendingPathComponent("unpacked")
        try NativeBackupArchive.extract(zip, to: dest)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dest.path))
        XCTAssertEqual(names, Set(["guiNDB.db", "guiNConfig.json"]))
        let copied = try RuntimeDatabase(url: dest.appendingPathComponent("guiNDB.db"))
        XCTAssertEqual(try copied.query("SELECT * FROM FutureData"), [["Value": .text("uncheckpointed")]])
    }
}
