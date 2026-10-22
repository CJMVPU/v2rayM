import XCTest
import Darwin
@testable import TunShared

final class FakeCore: ManagedCore {
    var pid: Int32 = 12345
    var isRunning = true
    var exitCode: Int32 = 0
    var ignoresTerminate = false
    var terminated = false
    var killed = false
    var beforeTerminate: (() -> Void)?
    func terminate() { beforeTerminate?(); terminated = true; if !ignoresTerminate { isRunning = false } }
    func forceKill() { killed = true; isRunning = false }
}

final class TunSessionTests: XCTestCase {
    var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }
    func data(_ action: String) throws -> Data { try JSONEncoder().encode(HelperRequest(action: action)) }
    func prepared() -> PreparedLaunch {
        PreparedLaunch(directory: temporary, executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:])
    }
    func testDisconnectStopsOnlyTheOwnedCoreAndRemovesPrivateConfiguration() throws {
        let core = FakeCore()
        let session = TunSession(limiter: SlotLimiter(), prepare: { _ in self.prepared() }, launch: { _, _ in core })
        XCTAssertEqual(session.handle(try data("start")).pid, core.pid)
        session.disconnect()
        XCTAssertTrue(core.terminated)
        XCTAssertFalse(core.killed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }
    func testForcedStopIsReportedAsUnconfirmedCleanup() throws {
        let core = FakeCore(); core.ignoresTerminate = true
        let session = TunSession(limiter: SlotLimiter(), graceSeconds: 0, prepare: { _ in self.prepared() }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try data("start")).success)
        let response = session.handle(try data("stop"))
        XCTAssertFalse(response.success)
        XCTAssertTrue(response.forced)
        XCTAssertEqual(response.code, "forced_stop_cleanup_unconfirmed")
    }
    func testUnknownActionsCannotExecuteCommands() throws {
        let session = TunSession(limiter: SlotLimiter(), prepare: { _ in XCTFail(); return self.prepared() })
        XCTAssertEqual(session.handle(try data("exec")).code, "action_not_allowed")
    }
    func testDuplicateStartDoesNotReplaceOwnedProcess() throws {
        let core = FakeCore()
        let session = TunSession(limiter: SlotLimiter(), prepare: { _ in self.prepared() }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try data("start")).success)
        XCTAssertEqual(session.handle(try data("start")).code, "session_already_running")
        session.disconnect()
    }
    func testGlobalLimitBoundsConcurrentCoresAndReleasesAfterDisconnect() throws {
        let limiter = SlotLimiter()
        func make() -> TunSession { TunSession(limiter: limiter, prepare: { _ in self.prepared() }, launch: { _, _ in FakeCore() }) }
        let first = make(), second = make(), third = make()
        XCTAssertTrue(first.handle(try data("start")).success)
        XCTAssertTrue(second.handle(try data("start")).success)
        XCTAssertEqual(third.handle(try data("start")).code, "helper_busy")
        first.disconnect()
        XCTAssertTrue(third.handle(try data("start")).success)
        second.disconnect(); third.disconnect()
    }
    func testExitedCoreBecomesFaultedAndReleasesResources() throws {
        let core = FakeCore()
        let session = TunSession(limiter: SlotLimiter(), prepare: { _ in self.prepared() }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try data("start")).success)
        core.exitCode = 1; core.isRunning = false
        XCTAssertEqual(session.handle(try data("status")).state, "faulted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }
    func testDnsIsRestoredBeforeStoppingCoreAndAfterUnexpectedExit() throws {
        let core = FakeCore(), network = FakeTunNetwork()
        let session = TunSession(limiter: SlotLimiter(), network: network, prepare: { _ in self.prepared() }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try data("start")).success)
        XCTAssertTrue(network.active)
        core.beforeTerminate = { XCTAssertFalse(network.active) }
        XCTAssertTrue(session.handle(try data("stop")).success)
        XCTAssertFalse(network.active)

        let second = FakeCore(), secondNetwork = FakeTunNetwork()
        let broken = TunSession(limiter: SlotLimiter(), network: secondNetwork, prepare: { _ in self.prepared() }, launch: { _, _ in second })
        XCTAssertTrue(broken.handle(try data("start")).success)
        second.isRunning = false; second.exitCode = 1
        XCTAssertEqual(broken.handle(try data("status")).state, "faulted")
        XCTAssertFalse(secondNetwork.active)
    }
    func testDnsInstallationFailureStopsTheOwnedCoreAndRestoresNetwork() throws {
        let core = FakeCore(), network = FakeTunNetwork(); network.installFails = true
        let session = TunSession(limiter: SlotLimiter(), network: network, prepare: { _ in self.prepared() }, launch: { _, _ in core })
        XCTAssertFalse(session.handle(try data("start")).success)
        XCTAssertFalse(core.isRunning)
        XCTAssertFalse(network.active)
    }
    func testDnsRestoreFailureKeepsResolverAliveAndReportsFailureUntilRetry() throws {
        let core = FakeCore(), network = FakeTunNetwork()
        let session = TunSession(limiter: SlotLimiter(), network: network, prepare: { _ in self.prepared() }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try data("start")).success)
        network.restoreFails = true
        let failed = session.handle(try data("stop"))
        XCTAssertFalse(failed.success); XCTAssertEqual(failed.code, "tun_dns_cleanup_failed")
        XCTAssertTrue(core.isRunning); XCTAssertTrue(network.active)
        network.restoreFails = false
        XCTAssertTrue(session.handle(try data("stop")).success)
        XCTAssertFalse(core.isRunning); XCTAssertFalse(network.active)
    }
    func testDisconnectRestoresTemporaryDns() throws {
        let core = FakeCore(), network = FakeTunNetwork()
        let session = TunSession(limiter: SlotLimiter(), network: network, prepare: { _ in self.prepared() }, launch: { _, _ in core })
        XCTAssertTrue(session.handle(try data("start")).success)
        session.disconnect()
        XCTAssertFalse(network.active); XCTAssertFalse(core.isRunning)
    }

    func testNativeProcessTerminatesGracefullyWithoutRootOrNetworking() throws {
        let session = TunSession(limiter: SlotLimiter(), prepare: { _ in self.prepared() })
        let started = session.handle(try data("start"))
        XCTAssertTrue(started.success, started.code)
        XCTAssertNotNil(started.pid)
        if let pid = started.pid { XCTAssertEqual(getpgid(pid), getpgrp()) }
        XCTAssertTrue(session.handle(try data("stop")).success)
    }
    func testChildDoesNotInheritTheDaemonsIgnoredTerminationSignal() throws {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let session = TunSession(limiter: SlotLimiter(), graceSeconds: 1, prepare: { _ in self.prepared() })
        XCTAssertTrue(session.handle(try data("start")).success)
        let stopped = session.handle(try data("stop"))
        XCTAssertTrue(stopped.success, stopped.code)
        XCTAssertFalse(stopped.forced)
    }
}

private final class FakeTunNetwork: ManagedTunNetwork {
    var active = false
    var installFails = false
    var restoreFails = false
    func install(_ settings: TunDNSSettings?) throws {
        active = true
        if installFails { throw HelperFailure("tun_dns_install_failed") }
    }
    func restore() throws {
        if restoreFails { throw HelperFailure("tun_dns_cleanup_failed") }
        active = false
    }
}
