import XCTest
import SwiftUI
import AppKit
@testable import V2rayMKit
@testable import V2rayM

final class ConnectionDashboardRenderingTests: XCTestCase {
    @MainActor func testRecentConnectionsSnapshot() throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_RECENT_RENDER_DIRECTORY"] else {
            throw XCTSkip("Set V2RAYM_RECENT_RENDER_DIRECTORY for recent-connection layout snapshots")
        }
        AppFont.register()
        let destinations = [("57.144.5.32", "proxy"), ("89.208.253.211", "proxy"),
                            ("[2606:4700:1234:5678:abcd:ef01:2345:6789]", "proxy"),
                            ("35.190.80.1", "block"), ("112.19.242.77", "direct")]
        let connections = try destinations.map { host, route in
            try XCTUnwrap(GlobeConnection.parse(LogEntry(timestamp: "2026-10-24T12:00:00Z", source: "core",
                message: "from tcp:127.0.0.1:1234 accepted tcp:\(host):443 [socks >> \(route)]", sequence: 1)))
        }
        for dark in [true, false] {
            let view = HStack(spacing: 12) {
                RecentConnectionsCard(connections: connections, coreRunning: true).frame(width: 280)
                RecentConnectionsCard(connections: [], coreRunning: true).frame(width: 280)
                RecentConnectionsCard(connections: Array(connections.prefix(1)), coreRunning: false).frame(width: 280)
            }.frame(height: 150).padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 888, height: 174)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let path = URL(fileURLWithPath: output).appendingPathComponent(dark ? "recent-dark.png" : "recent-light.png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        }
    }

    @MainActor func testDiscHoverSnapshot() throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_HOVER_RENDER"] else {
            throw XCTSkip("Set V2RAYM_HOVER_RENDER for an offline hover comparison")
        }
        let view = HStack(spacing: 32) {
            DashboardDiscSurface(hovered: false)
            DashboardDiscSurface(hovered: true)
        }.padding(24).frame(width: 700, height: 350)
            .background(Color(nsColor: .controlBackgroundColor)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 350)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }

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
