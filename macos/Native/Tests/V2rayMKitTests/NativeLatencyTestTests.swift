import Darwin
import XCTest
@testable import V2rayMKit

final class NativeLatencyTestTests: XCTestCase {
    func testSuccessfulLoopbackTCPHandshakesAlwaysHaveDisplayableLatency() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                guard Darwin.bind(listener, sa, length) == 0, listen(listener, 16) == 0,
                      getsockname(listener, sa, &length) == 0 else { throw POSIXError(.EADDRINUSE) }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let port = UInt16(bigEndian: address.sin_port)
        _ = try await store.importProfiles(content: "socks://127.0.0.1:\(port)#Local", groupID: "", isSubscription: false)
        let rows = try await store.profileCatalog()
        let node = try XCTUnwrap(rows.first)
        for _ in 0..<8 {
            let delay = try await NativeLatencyTest.measure(node)
            XCTAssertGreaterThan(delay, 0)
        }
    }

    func testOnlyTheGraphThatWasMeasuredCanSaveSuccessOrFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO SubItem(Id, Remarks) VALUES ('s','Sub')")
        _ = try db.query("""
            INSERT INTO ProfileItem(IndexId, ConfigType, ConfigVersion, Remarks, Address, Port, Subid)
            VALUES ('child',4,4,'Child','127.0.0.1',1100,'s'),('other',4,4,'Other','127.0.0.2',1200,'')
            """)
        _ = try db.query("""
            INSERT INTO ProfileItem(IndexId,ConfigType,ConfigVersion,Remarks,ProtoExtra)
            VALUES ('parent',101,4,'Group','{"ChildItems":"child"}')
            """)
        let profiles = try await store.profileCatalog()
        let group = try XCTUnwrap(profiles.first { $0.id == "parent" })
        let child = try XCTUnwrap(profiles.first { $0.id == "child" })
        let snapshot = try await store.configurationSnapshot()
        let attempt = NativeDiagnosticAttempt(node: group, snapshot: snapshot)
        let single = NativeDiagnosticAttempt(node: child, snapshot: snapshot)
        XCTAssertNotNil(attempt.configuration)
        _ = try db.query("UPDATE ProfileItem SET Port=1201 WHERE IndexId='other'")
        let saved = try await store.recordLatency(77, for: group, ipInfo: "previous", original: snapshot.original(group.id), attempt: attempt)
        XCTAssertTrue(saved)
        _ = try db.query("UPDATE ProfileItem SET Port=1101 WHERE IndexId='child'")
        for delay in [-1, 3] {
            let stale = try await store.recordLatency(delay, for: group, speed: 20, ipInfo: "stale",
                                                     original: snapshot.original(group.id), attempt: attempt)
            XCTAssertFalse(stale)
        }
        XCTAssertEqual(try db.query("SELECT Delay,IpInfo,Speed FROM ProfileExItem WHERE IndexId='parent'"),
                       [["Delay": .integer(77), "IpInfo": .text("previous"), "Speed": .null]])
        _ = try db.query("UPDATE ProfileItem SET Port=1100 WHERE IndexId='child'")
        _ = try db.query("UPDATE SubItem SET PrevProfile='Other' WHERE Id='s'")
        let changed = try await store.recordLatency(99, for: child, original: snapshot.original(child.id), attempt: single)
        XCTAssertFalse(changed, "Adding a hop changes the effective chain of an ordinary subscription node")
    }
}
