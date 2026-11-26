import Darwin
import Foundation
import XCTest
@testable import V2rayMKit

final class StartupLeaseTests: XCTestCase {
    func testFailedJournalFinalizationReleasesRecoveredListenerBeforeUnlockingStore() async throws {
        guard let app = ProcessInfo.processInfo.environment["V2RAYM_TEST_SIGNED_APP"] else {
            throw XCTSkip("Set V2RAYM_TEST_SIGNED_APP to exercise the packaged Xray")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let port = try Self.freePort()
        let config = "{\"inbounds\":[{\"listen\":\"127.0.0.1\",\"port\":\(port),\"protocol\":\"http\"}],\"outbounds\":[{\"protocol\":\"freedom\"}]}"
        let folder = root.appendingPathComponent("guiConfigs")
        try Data(config.utf8).write(to: folder.appendingPathComponent("fixture.json"))
        let db = try RuntimeDatabase(url: folder.appendingPathComponent("guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem(IndexId, ConfigType, CoreType, Remarks, Address) VALUES ('fixture',2,2,'Fixture','fixture.json')")
        try NativeBackupRestore(data: root).begin(.init(id: UUID(), runningNode: "fixture"))
        let journal = root.appendingPathComponent("native-pending-restore.json").path
        guard chflags(journal, UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError(.EPERM) }
        defer { _ = chflags(journal, 0) }
        let host = NativeRuntimeHost(bundle: URL(fileURLWithPath: app), dataDirectory: root, mayContactHelper: false, automaticMaintenance: false)
        do {
            _ = try await host.startClient()
            XCTFail("Immutable recovery journal must prevent finalization")
        } catch {
            let logs = await host.history.recent(limit: 100, filter: nil)
            XCTAssertTrue(logs.contains { $0.message.contains("Xray 已启动") }, "The recovered listener must have started before the failure")
        }
        XCTAssertNoThrow(try Self.freePort(requested: port), "A failed startup must release its listener")
        try await host.stop()
        XCTAssertEqual(chflags(journal, 0), 0)
        _ = try await host.startClient()
        let state = try await host.runtimeStatus()
        XCTAssertEqual(state.runningProfileId, "fixture")
        try await host.stop()
    }

    private static func freePort(requested: UInt16 = 0) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = requested.bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        return try withUnsafeMutablePointer(to: &addr) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(fd, $0, size) == 0, getsockname(fd, $0, &size) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return UInt16(bigEndian: UnsafeRawPointer($0).load(as: sockaddr_in.self).sin_port)
            }
        }
    }
}
