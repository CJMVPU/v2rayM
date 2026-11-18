import XCTest
import AppKit
import SwiftUI
@testable import V2rayM
@testable import V2rayMKit

@MainActor private final class MotionFixture: ObservableObject {
    @Published var active = false
    @Published var ready = false
    @Published var rows: [GlobeConnection] = []
}
private struct MotionFixtureView: View {
    @ObservedObject var fixture: MotionFixture
    var body: some View {
        RealityWindow {
        HStack(spacing: 12) {
            ConnectionDashboard(state: fixture.active ? .system : .stopped, city: "洛杉矶", nodeName: "Preview",
                node: nil, startedAt: "2026-11-16T00:00:00Z", coreRunning: fixture.active, rates: nil,
                trend: TrafficTrend(), trafficEnabled: true, now: Date(), connecting: false, reconnect: {})
                .frame(width: 550, height: 546)
            RecentConnectionsCard(connections: fixture.rows, coreRunning: fixture.active, dataReady: fixture.ready).frame(width: 280, height: 205)
        }.padding(12).environment(\.colorScheme, .dark)
        }.environment(\.dashboardVisibilityOverride, true)
    }
}
final class DashboardMotionRenderingTests: XCTestCase {
    @MainActor func testActivationRefreshAndRapidReplacementSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["V2RAYM_MOTION_RENDER_DIRECTORY"] else {
            throw XCTSkip("Set V2RAYM_MOTION_RENDER_DIRECTORY to capture live animation phases")
        }
        AppFont.register()
        func rows(_ group: Int) throws -> [GlobeConnection] {
            try (1...7).map { index in
                try XCTUnwrap(GlobeConnection.parse(LogEntry(timestamp: "2026-11-16T12:00:00Z", source: "core",
                    message: "from tcp:127.0.0.1:1234 accepted tcp:192.0.\(group).\(index):443 [socks >> proxy]", sequence: Int64(index))))
            }
        }
        let fixture = MotionFixture()
        fixture.rows = try rows(1)
        let host = NSHostingView(rootView: MotionFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 866, height: 570),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        defer { window.close() }
        @discardableResult func capture(_ name: String) throws -> URL {
            host.layoutSubtreeIfNeeded()
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + "-screen.png")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            return url
        }
        try await Task.sleep(for: .milliseconds(100))
        try capture("motion-0-stopped")
        fixture.active = true
        try await Task.sleep(for: .milliseconds(380))
        try capture("motion-1-activating")
        try await Task.sleep(for: .milliseconds(300))
        try capture("motion-1-waiting-data")
        fixture.ready = true
        try await Task.sleep(for: .milliseconds(1500))
        try capture("motion-1-card-turn")
        try await Task.sleep(for: .milliseconds(2000))
        try capture("motion-2-ready")
        fixture.rows = try rows(2)
        try await Task.sleep(for: .milliseconds(500))
        try capture("motion-3-row-native-turn")
        fixture.rows = try rows(3)
        try await Task.sleep(for: .milliseconds(5200))
        let latestCapture = try capture("motion-4-latest")
        // Compare the settled rendering against a fresh view of the final rows;
        // a rapid replacement must leave the latest text after staggered turns.
        let actual = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: latestCapture)))
        let fresh = NSHostingView(rootView: MotionFixtureView(fixture: fixture))
        fresh.frame = host.bounds
        fresh.appearance = NSAppearance(named: .darkAqua)
        window.contentView = fresh
        try await Task.sleep(for: .milliseconds(500))
        fresh.layoutSubtreeIfNeeded()
        let reference = try capture("motion-4-reference")
        let settled = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: reference)))
        // Row region excludes the live timer on the left.
        var mismatches = 0
        var compared = 0
        for y in stride(from: 0, to: actual.pixelsHigh, by: 8) {
            for x in stride(from: actual.pixelsWide * 2 / 3, to: actual.pixelsWide, by: 8) {
                compared += 1
                if actual.colorAt(x: x, y: y) != settled.colorAt(x: x, y: y) { mismatches += 1 }
            }
        }
        XCTAssertLessThan(Double(mismatches) / Double(compared), 0.01,
                          "Settled connection rows must match a fresh rendering of the latest data")
        window.contentView = host
        fixture.active = false
        fixture.rows = []
        fixture.ready = false
        try await Task.sleep(for: .milliseconds(150))
        try capture("motion-5-stopping")
        try await Task.sleep(for: .milliseconds(1500))
        try capture("motion-5-closing-turn")
        try await Task.sleep(for: .milliseconds(2000))
        try capture("motion-6-resting")
    }
}
