import XCTest
@testable import TunShared

final class SessionRecoveryStoreTests: XCTestCase {
    func testReceiptSurvivesLostConnectionAndOnlyConfirmsTheOriginalToken() {
        let store = SessionRecoveryStore(), token = UUID().uuidString
        XCTAssertTrue(store.begin(token))
        XCTAssertFalse(store.begin(token))
        XCTAssertEqual(store.status(token).code, "session_cleanup_pending")
        XCTAssertFalse(store.status(UUID().uuidString).success)
        store.finish(token, confirmed: true)
        XCTAssertTrue(store.status(token).success)
        XCTAssertEqual(store.status(token).code, "session_cleanup_confirmed")
        XCTAssertEqual(store.status(token).state, "stopped")
        XCTAssertFalse(SessionRecoveryStore().status(token).success, "a daemon restart loses proof, never implies cleanup")
    }

    func testUnconfirmedCleanupAndUnknownTokensNeverBecomeSuccess() {
        let store = SessionRecoveryStore(), token = UUID().uuidString
        XCTAssertFalse(store.begin(nil)); XCTAssertFalse(store.begin("invalid"))
        XCTAssertTrue(store.begin(token))
        store.finish(token, confirmed: false)
        store.finish(token, confirmed: true)
        XCTAssertFalse(store.status(token).success)
        XCTAssertEqual(store.status(token).code, "session_cleanup_unconfirmed")
    }

    func testBoundedReceiptsNeverEvictPendingOwnersOrTreatEvictionAsProof() {
        let store = SessionRecoveryStore(capacity: 2)
        let first = UUID().uuidString, second = UUID().uuidString, third = UUID().uuidString
        XCTAssertTrue(store.begin(first)); XCTAssertTrue(store.begin(second))
        XCTAssertFalse(store.begin(third))
        store.finish(first, confirmed: true)
        XCTAssertTrue(store.begin(third))
        XCTAssertEqual(store.status(second).code, "session_cleanup_pending")
        XCTAssertEqual(store.status(first).code, "session_cleanup_unknown")
    }
}
