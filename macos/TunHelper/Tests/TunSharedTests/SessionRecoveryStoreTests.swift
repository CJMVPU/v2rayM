import XCTest
@testable import TunShared

final class SessionRecoveryStoreTests: XCTestCase {
    func testReceiptSurvivesLostConnectionAndOnlyConfirmsTheOriginalToken() throws {
        let store = SessionRecoveryStore(), token = UUID().uuidString
        XCTAssertTrue(try store.begin(token))
        XCTAssertFalse(try store.begin(token))
        XCTAssertEqual(store.status(token).code, "session_cleanup_pending")
        XCTAssertFalse(store.status(UUID().uuidString).success)
        try store.finish(token, confirmed: true)
        XCTAssertTrue(store.status(token).success)
        XCTAssertEqual(store.status(token).code, "session_cleanup_confirmed")
        XCTAssertEqual(store.status(token).state, "stopped")
        XCTAssertFalse(SessionRecoveryStore().status(token).success, "a store without the original archive has no proof")
    }

    func testDaemonRestartPreservesOnlyCompletedProofForTheOriginalUser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = UUID().uuidString, pending = UUID().uuidString, failed = UUID().uuidString
        let first = try SessionRecoveryStore(directory: root)
        for token in [completed, pending, failed] { XCTAssertTrue(try first.begin(token, owner: 501)) }
        try first.finish(completed, confirmed: true, owner: 502)
        XCTAssertEqual(first.status(completed, owner: 501).code, "session_cleanup_pending")
        try first.finish(completed, confirmed: true, owner: 501)
        try first.finish(failed, confirmed: false, owner: 501)

        let restarted = try SessionRecoveryStore(directory: root)
        XCTAssertTrue(restarted.status(completed, owner: 501).success)
        XCTAssertFalse(try restarted.begin(completed, owner: 502))
        XCTAssertEqual(restarted.status(completed, owner: 502).code, "session_cleanup_unknown")
        for token in [pending, failed, UUID().uuidString] {
            XCTAssertEqual(restarted.status(token, owner: 501).code, "session_cleanup_unknown")
        }
    }

    func testEvictedProofIsRemovedBeforeItsTokenCanBeReused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID().uuidString, next = UUID().uuidString
        let store = try SessionRecoveryStore(directory: root, capacity: 1)
        XCTAssertTrue(try store.begin(first))
        try store.finish(first, confirmed: true)
        XCTAssertTrue(try store.begin(next))
        let restarted = try SessionRecoveryStore(directory: root, capacity: 1)
        XCTAssertEqual(restarted.status(first).code, "session_cleanup_unknown")
        XCTAssertTrue(try restarted.begin(first))
        XCTAssertEqual(restarted.status(first).code, "session_cleanup_pending")
    }

    func testWriteFailureLeavesCompletionPendingForRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionRecoveryStore(directory: root), token = UUID().uuidString
        XCTAssertTrue(try store.begin(token))
        let archive = root.appendingPathComponent("completed.json")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.finish(token, confirmed: true))
        XCTAssertEqual(store.status(token).code, "session_cleanup_pending")
        try FileManager.default.removeItem(at: archive)
        try store.finish(token, confirmed: true)
        XCTAssertTrue(try SessionRecoveryStore(directory: root).status(token).success)
    }

    func testRejectsSharedReceiptDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try SessionRecoveryStore(directory: root))
    }

    func testUnconfirmedCleanupAndUnknownTokensNeverBecomeSuccess() throws {
        let store = SessionRecoveryStore(), token = UUID().uuidString
        XCTAssertFalse(try store.begin(nil)); XCTAssertFalse(try store.begin("invalid"))
        XCTAssertTrue(try store.begin(token))
        try store.finish(token, confirmed: false)
        try store.finish(token, confirmed: true)
        XCTAssertFalse(store.status(token).success)
        XCTAssertEqual(store.status(token).code, "session_cleanup_unconfirmed")
    }

    func testBoundedReceiptsNeverEvictPendingOwnersOrTreatEvictionAsProof() throws {
        let store = SessionRecoveryStore(capacity: 2)
        let first = UUID().uuidString, second = UUID().uuidString, third = UUID().uuidString
        XCTAssertTrue(try store.begin(first)); XCTAssertTrue(try store.begin(second))
        XCTAssertFalse(try store.begin(third))
        try store.finish(first, confirmed: true)
        XCTAssertTrue(try store.begin(third))
        XCTAssertEqual(store.status(second).code, "session_cleanup_pending")
        XCTAssertEqual(store.status(first).code, "session_cleanup_unknown")
    }
}
