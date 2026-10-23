import XCTest
@testable import V2rayMKit

final class DashboardStatusTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)
    func state(_ running: Bool, runtime: String = "running") throws -> RuntimeStatus {
        try JSONDecoder().decode(RuntimeStatus.self, from: Data("{\"coreRunning\":\(running),\"xrayAvailable\":true,\"runtimeState\":\"\(runtime)\"}".utf8))
    }
    func testOfflineAndStaleNeverDisplayConnected() throws {
        let s = try state(true)
        XCTAssertEqual(DashboardStatus.resolve(ready: false, updating: false, busy: false, recovery: false, state: s, tunRunning: true, systemProxy: false, lastRefresh: now, now: now), .offline)
        XCTAssertEqual(DashboardStatus.resolve(ready: true, updating: false, busy: false, recovery: false, state: s, tunRunning: true, systemProxy: false, lastRefresh: now.addingTimeInterval(-9), now: now), .stale)
    }
    func testModesRequireRunningCoreAndRecoveryOverridesGreen() throws {
        let running = try state(true), stopped = try state(false, runtime: "stopped")
        for (core, tun, system, recovery, expected) in [(running,true,false,false,DashboardStatus.tun), (running,false,true,false,.system), (running,false,false,false,.local), (stopped,true,true,false,.stopped), (running,true,false,true,.faulted)] {
            XCTAssertEqual(DashboardStatus.resolve(ready: true, updating: false, busy: false, recovery: recovery, state: core, tunRunning: tun, systemProxy: system, lastRefresh: now, now: now), expected)
        }
    }
    func testUpdateRemainsPendingRatherThanClaimingStopped() throws {
        XCTAssertEqual(DashboardStatus.resolve(ready: true, updating: true, busy: false, recovery: false, state: try state(false), tunRunning: false, systemProxy: false, lastRefresh: nil, now: now), .updating)
    }
    func testTrafficUsesActualIntervalAndExpires() throws {
        let traffic = try JSONDecoder().decode(RuntimeTraffic.self, from: Data(#"{"proxyUp":10,"proxyDown":20,"directUp":4,"directDown":8,"sampleSeconds":2,"sampledAt":"1970-01-01T00:16:40Z"}"#.utf8))
        XCTAssertEqual(traffic.rates(at: now), [5,10,2,4])
        XCTAssertNil(traffic.rates(at: now.addingTimeInterval(13)))
        XCTAssertEqual(DashboardStatus.rate(2048), "2.0 MiB/s")
        XCTAssertEqual(DashboardStatus.rate(nil), "—")
    }
    func testDurationAndNewRouteHaveNoOldIdentity() {
        XCTAssertEqual(DashboardStatus.duration(since: "1970-01-01T00:00:00Z", now: now), "00:16:40")
        let draft = RoutingDraft.newProfile()
        XCTAssertEqual(draft["id"], .null)
        XCTAssertFalse(draft["isActive"].flag)
        XCTAssertEqual(draft["ruleSet"].text, "[]")
        XCTAssertFalse(draft["remarks"].text.isEmpty)
    }
    func testTrafficAvailabilityAndPersistentAmounts() {
        XCTAssertEqual(DashboardStatus.trafficDescription(state: .stopped, enabled: true, hasSample: false), "采集已开启 · 等待连接")
        XCTAssertEqual(DashboardStatus.trafficDescription(state: .tun, enabled: false, hasSample: false), "流量采集未开启")
        XCTAssertEqual(DashboardStatus.trafficDescription(state: .tun, enabled: true, hasSample: false), "等待有效采样")
        XCTAssertEqual(DashboardStatus.trafficDescription(state: .system, enabled: true, hasSample: true), "5 秒采样 · 1 分钟均速")
        XCTAssertEqual(DashboardStatus.amount(1048576), "1.00 GiB")
        XCTAssertEqual(DashboardStatus.amount(0), "0.0 KiB")
        XCTAssertEqual(DashboardStatus.amount(nil), "—")
    }

    func testMenuBarModeNeverUsesActiveColorForPendingOrBrokenState() {
        XCTAssertEqual(MenuBarMode(.stopped), .inactive)
        XCTAssertEqual(MenuBarMode(.system), .system)
        XCTAssertEqual(MenuBarMode(.tun), .tun)
        for state: DashboardStatus in [.offline, .faulted, .stale, .updating, .changing, .local] {
            XCTAssertEqual(MenuBarMode(state), .attention)
        }
    }

}
