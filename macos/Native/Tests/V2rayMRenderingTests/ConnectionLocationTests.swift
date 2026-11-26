import XCTest
@testable import V2rayM
@testable import V2rayMKit

private actor LocationRequests {
    private(set) var hosts: [String] = []
    func lookup(_ host: String) -> GlobePlace {
        hosts.append(host)
        return GlobePlace(city: host, latitude: 0, longitude: 0)
    }
}

final class ConnectionLocationTests: XCTestCase {
    @MainActor func testOnlyTheConfiguredNodeHostnameAndLoggedIPsReachTheResolver() async throws {
        let requests = LocationRequests()
        let monitor = GlobeMonitor(resolver: GlobeLookupCache { await requests.lookup($0) })
        let status = try JSONDecoder().decode(RuntimeStatus.self, from: Data(#"{"runningProfileId":"node","coreRunning":true,"xrayAvailable":true,"runtimeState":"running"}"#.utf8))
        let node = try JSONDecoder().decode(Profile.self, from: Data(#"{"indexId":"node","remarks":"test","address":"node.invalid","port":1080,"protocol":"socks","network":"raw","coreType":"xray","delay":0,"isCurrent":true,"canTest":true}"#.utf8))
        let entries = [("private-proxy.invalid", "proxy"), ("private-direct.invalid", "direct"),
                       ("192.0.2.12", "proxy"), ("[2001:db8::57]", "direct")].enumerated().map { index, pair in
            LogEntry(timestamp: "2026-11-24T00:00:00Z", source: "core",
                     message: "from test accepted tcp:\(pair.0):443 [socks >> \(pair.1)]", sequence: Int64(index))
        }
        monitor.update(state: status, node: node, recent: GlobeConnection.recent(entries, previous: [], since: .distantPast))
        let deadline = ContinuousClock.now + .seconds(2)
        while (monitor.nodePlace == nil || monitor.connections.filter({ $0.place != nil }).count < 2) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let hosts = await requests.hosts
        XCTAssertEqual(Set(hosts), ["node.invalid", "192.0.2.12", "2001:db8::57"])
        XCTAssertEqual(monitor.nodePlace?.city, "node.invalid")
        XCTAssertEqual(monitor.connections.count, 4)
        XCTAssertTrue(monitor.connections.filter { $0.host.hasSuffix(".invalid") }.allSatisfy { $0.place == nil })
    }
}
