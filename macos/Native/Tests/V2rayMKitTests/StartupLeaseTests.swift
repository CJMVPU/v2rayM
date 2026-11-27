import Darwin
import Foundation
import XCTest
@testable import V2rayMKit

final class StartupLeaseTests: XCTestCase {
    func testRunningOrdinaryProxyPollsStatusWithoutOpeningAnyHelperChannel() async throws {
        guard let app = ProcessInfo.processInfo.environment["V2RAYM_TEST_SIGNED_APP"] else {
            throw XCTSkip("Set V2RAYM_TEST_SIGNED_APP to exercise the packaged Xray")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = NativeHelperSession { _ in
            XCTFail("Polling the ordinary proxy attempted to connect to the privileged helper")
            throw ClientFailure("unexpected_helper_connection")
        }
        let host = NativeRuntimeHost(bundle: URL(fileURLWithPath: app), dataDirectory: root, helper: helper)
        let client = try await host.startClient()
        do {
            let port = try Self.freePort()
            let config = #"{"inbounds":[{"listen":"127.0.0.1","port":\#(port),"protocol":"http"}],"outbounds":[{"protocol":"freedom"}]}"#
            let folder = root.appendingPathComponent("guiConfigs")
            try Data(config.utf8).write(to: folder.appendingPathComponent("proxy.json"))
            let db = try RuntimeDatabase(url: folder.appendingPathComponent("guiNDB.db"), writable: true)
            _ = try db.query("INSERT INTO ProfileItem(IndexId, ConfigType, CoreType, Remarks, Address) VALUES ('proxy',2,2,'Local','proxy.json')")
            try await client.selectProfile("proxy", connect: true)
            let before = try await client.runtimeStatus()
            XCTAssertTrue(before.coreRunning)
            XCTAssertEqual(before.runningProfileId, "proxy")
            for mode: TunStatusReadMode in [.normal, .fresh, .normal] {
                let status = try await client.tunStatus(mode)
                XCTAssertFalse(status.enabled)
                XCTAssertFalse(status.isRunning)
                XCTAssertEqual(status.runtimeState, "running")
            }
            let after = try await client.runtimeStatus()
            XCTAssertEqual(after.coreSessionID, before.coreSessionID)
        } catch { try await host.stop(); throw error }
        try await host.stop()
    }

    func testTunnelConflictRollsBackPersistedModeAndRelaunchesProxy() async throws {
        guard let app = ProcessInfo.processInfo.environment["V2RAYM_TEST_SIGNED_APP"] else {
            throw XCTSkip("Set V2RAYM_TEST_SIGNED_APP to exercise the packaged Xray")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = DescriptorFixture(reader: .nullDevice)
        let listener = NSXPCListener.anonymous()
        listener.delegate = fixture
        listener.resume()
        defer { listener.invalidate() }
        let helper = NativeHelperSession { callback in
            NativeHelperChannel(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), onDisconnect: callback)
        }
        let store = NativeConfigurationStore(dataDirectory: root)
        let host = NativeRuntimeHost(bundle: URL(fileURLWithPath: app), dataDirectory: root, helper: helper) {
            let persisted = try await store.readSettings()
            XCTAssertEqual(persisted["TunModeItem"]["EnableTun"], .bool(true))
            throw ClientFailure("tun_conflict")
        }
        let api = try await host.startClient()
        do {
            let port = Int(try Self.freePort())
            try await api.saveSettings(.inbound, SettingsValue.object(["localPort": .number(Double(port))]))
            try await api.importProfiles("socks://127.0.0.1:1#Local", group: "", isSubscription: false)
            let nodes = try await api.profileMetadata()
            let id = try XCTUnwrap(nodes.first?.id)
            try await api.selectProfile(id, connect: true)
            let before = try await api.runtimeStatus()
            let originalSession = try XCTUnwrap(before.coreSessionID)
            do { try await api.setTunEnabled(true); XCTFail("Refused tunnel was accepted") }
            catch let error as ClientFailure { XCTAssertEqual(error.code, "tun_conflict") }

            XCTAssertTrue(fixture.plans.isEmpty, "Conflict detection must precede opening a tunnel")
            let settings = try await host.store.readSettings()
            XCTAssertEqual(settings["TunModeItem"]["EnableTun"], .bool(false))
            XCTAssertEqual(settings["IndexId"].text, id)
            let restored = try await api.runtimeStatus()
            XCTAssertTrue(restored.coreRunning)
            XCTAssertEqual(restored.runningProfileId, id)
            XCTAssertEqual(restored.runningProxyPort, port)
            XCTAssertNotEqual(try XCTUnwrap(restored.coreSessionID), originalSession)
        } catch { try await host.stop(); throw error }
        try await host.stop()
    }

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

    func testCustomProfileStartupDiagnosticsHideCredentialsInHostLogs() async throws {
        guard let app = ProcessInfo.processInfo.environment["V2RAYM_TEST_SIGNED_APP"] else {
            throw XCTSkip("Set V2RAYM_TEST_SIGNED_APP to exercise the packaged Xray")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let fakeSecret = "private-test-marker"
        let payload = #"{"inbounds":[],"outbounds":[{"protocol":"shadowsocks","tag":"proxy","settings":{"address":"127.0.0.1","port":9,"method":"2022-blake3-aes-128-gcm","password":"\#(fakeSecret)"}}]}"#
        _ = try await store.importProfiles(content: payload, groupID: nil, isSubscription: false)
        let catalog = try await store.profileCatalog()
        var settings = try await store.readSettings()
        settings["IndexId"] = .string(try XCTUnwrap(catalog.first?.id))
        try await store.writeSettings(settings)
        let host = NativeRuntimeHost(bundle: URL(fileURLWithPath: app), dataDirectory: root, mayContactHelper: false, automaticMaintenance: false)
        _ = try await host.startClient()
        do {
            try await host.startCore()
            XCTFail("The packaged core accepted an invalid custom PSK")
        } catch let failure as ClientFailure {
            XCTAssertEqual(failure.code, "core_start_failed")
            XCTAssertFalse(failure.localizedDescription.contains(fakeSecret))
        }
        let logs = await host.history.recent(limit: 100, filter: nil)
        XCTAssertTrue(logs.contains { $0.message.contains("Xray 启动失败") && $0.message.contains("Shadowsocks 2022") })
        XCTAssertFalse(logs.contains { $0.message.contains(fakeSecret) })
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
