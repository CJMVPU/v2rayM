import XCTest
@testable import TunShared

final class SessionCleanupCoordinatorTests: XCTestCase {
    func testForcedExitReleasesOwnedResourcesButDoesNotClaimConfirmedShutdownRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = FakeCore(); core.ignoresTerminate = true
        let session = TunSession(limiter: SlotLimiter(), graceSeconds: 0, prepare: { _ in
            PreparedLaunch(directory: root, executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [], environment: [:])
        }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try JSONEncoder().encode(HelperRequest(action: "start"))).success)
        XCTAssertFalse(SessionShutdownCoordinator.stop([{ session.disconnect(requireConfirmedRecovery: true) }], timeout: 0.03, retryDelay: 0.005))
        XCTAssertTrue(core.killed)
        XCTAssertFalse(core.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(session.disconnect(), "resource ownership can be released without claiming graceful route recovery")
    }
    func testShutdownFailureReportsUnconfirmedRecoveryAndCanRetryTheSameOwnedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = RetryNetwork {}, core = FakeCore(), limiter = SlotLimiter()
        let session = TunSession(limiter: limiter, network: network, prepare: { _ in
            PreparedLaunch(directory: root, executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [], environment: [:])
        }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try JSONEncoder().encode(HelperRequest(action: "start"))).success)
        XCTAssertFalse(SessionShutdownCoordinator.stop([{ session.disconnect() }], timeout: 0.05, retryDelay: 0.005))
        XCTAssertTrue(core.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        network.allowRestore()
        XCTAssertTrue(SessionShutdownCoordinator.stop([{ session.disconnect() }], timeout: 1, retryDelay: 0.005))
        XCTAssertFalse(core.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(limiter.acquire(UUID()))
        XCTAssertTrue(limiter.acquire(UUID()))
    }
    func testShutdownRetriesTransientDnsFailureBeforeDeadline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = RetryNetwork {}, core = FakeCore()
        let session = TunSession(limiter: SlotLimiter(), network: network, prepare: { _ in
            PreparedLaunch(directory: root, executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [], environment: [:])
        }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try JSONEncoder().encode(HelperRequest(action: "start"))).success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.025) { network.allowRestore() }
        XCTAssertTrue(SessionShutdownCoordinator.stop([{ session.disconnect() }], timeout: 1, retryDelay: 0.005))
        XCTAssertFalse(core.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testDisconnectedSessionIsRetainedAndRetriedUntilDnsCleanupAndSlotRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = expectation(description: "first cleanup failed")
        let completed = expectation(description: "cleanup completed after retry")
        let network = RetryNetwork { failed.fulfill() }
        let limiter = SlotLimiter(), core = FakeCore()
        var session: TunSession? = TunSession(limiter: limiter, network: network, prepare: { _ in
            PreparedLaunch(directory: root, executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [], environment: [:])
        }, launch: { _, _ in core })
        XCTAssertTrue(session!.handle(try JSONEncoder().encode(HelperRequest(action: "start"))).success)
        let retained = WeakSession(session!)
        let coordinator = SessionCleanupCoordinator(retryDelay: 0.01)
        coordinator.disconnect(id: UUID(), cleanup: { [owned = session!] in owned.disconnect() }) {
            XCTAssertFalse(core.isRunning)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            XCTAssertTrue(limiter.acquire(UUID()))
            XCTAssertTrue(limiter.acquire(UUID()))
            completed.fulfill()
        }
        session = nil
        wait(for: [failed], timeout: 2)
        XCTAssertNotNil(retained.value)
        XCTAssertTrue(core.isRunning, "DNS must be restored before terminating the resolver")
        network.allowRestore()
        wait(for: [completed], timeout: 2)
    }
}

private final class WeakSession {
    weak var value: TunSession?
    init(_ value: TunSession) { self.value = value }
}

private final class RetryNetwork: ManagedTunNetwork {
    private let lock = NSLock()
    private var allowed = false
    private var reported = false
    private let onFailure: () -> Void
    init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }
    func install(_ settings: TunDNSSettings?) throws {}
    func allowRestore() { lock.lock(); allowed = true; lock.unlock() }
    func restore() throws {
        lock.lock(); defer { lock.unlock() }
        guard allowed else {
            if !reported { reported = true; onFailure() }
            throw HelperFailure("tun_dns_cleanup_failed")
        }
    }
}
