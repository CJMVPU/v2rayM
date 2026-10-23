import XCTest
import SwiftUI
import AppKit
import V2rayMKit
@testable import V2rayM

final class ConnectionDashboardRenderingTests: XCTestCase {
    @MainActor func testDashboardSnapshot() throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_DASHBOARD_RENDER"] else {
            throw XCTSkip("Set V2RAYM_DASHBOARD_RENDER for an offline dashboard snapshot")
        }
        AppFont.register()
        let now = Date()
        let formatter = ISO8601DateFormatter()
        var trend = TrafficTrend()
        for i in 0...60 {
            let date = now.addingTimeInterval(Double(i - 60) * 5)
            let data: [String: Any] = ["coreRunning": true, "xrayAvailable": true, "runtimeState": "running",
                "runningProfileId": "fixture", "coreStartedAt": formatter.string(from: now.addingTimeInterval(-600)),
                "trafficEnabled": true, "traffic": ["proxyUp": Double(20 + i % 13) * 60,
                    "proxyDown": Double(800 + i % 19 * 100) * 60,
                    "directUp": 0, "directDown": 0, "sampleSeconds": 60,
                    "sampledAt": formatter.string(from: date)]]
            let state = try JSONDecoder().decode(RuntimeStatus.self, from: JSONSerialization.data(withJSONObject: data))
            trend.record(state, now: date)
        }
        let dashboard = ConnectionDashboard(state: .tun, city: "洛杉矶", nodeName: "Vless_xray", node: nil,
            startedAt: formatter.string(from: now.addingTimeInterval(-351)), coreRunning: true,
            rates: [25, 1300], trend: trend, trafficEnabled: true, now: now, connecting: false, reconnect: {})
            .frame(width: 550, height: 546).padding(12)
            .background(Color(nsColor: .controlBackgroundColor)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: dashboard)
        host.frame = CGRect(x: 0, y: 0, width: 574, height: 570)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
