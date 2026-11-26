import AppKit
import RealityKit
import SwiftUI
import XCTest
@testable import V2rayM
@testable import V2rayMKit

@MainActor final class DashboardHoverTests: XCTestCase {
    func testHoverMovesOnlyTheIntendedSolidAndKeepsTheNativeTargetsAndRowColours() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(dataDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), stamp = ISO8601DateFormatter().string(from: now)
        model.ready = true
        model.lastStatusRefresh = now
        let status = try JSONDecoder().decode(RuntimeStatus.self, from: JSONSerialization.data(withJSONObject:
            ["coreRunning": true, "xrayAvailable": true, "runningProfileId": "fixture", "runtimeState": "running",
             "coreStartedAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-360)), "trafficEnabled": true,
             "traffic": ["proxyUp": 100, "proxyDown": 200, "directUp": 300, "directDown": 400, "sampleSeconds": 1, "sampledAt": stamp]]))
        model.status = status
        model.telemetry.record(status, now: now)
        let logs = ["proxy", "direct"].enumerated().map { i, route in
            LogEntry(timestamp: stamp, source: "core", message: "from test accepted tcp:192.0.2.\(i + 1):443 [socks >> \(route)]", sequence: Int64(i))
        }
        model.dashboard.update(state: status, node: nil, recent: GlobeConnection.recent(logs, previous: [], since: .distantPast))
        let host = NSHostingView(rootView: ContentView().environmentObject(model)
            .environment(\.dashboardVisibilityOverride, true).environment(\.presentsInitialDashboard, true).preferredColorScheme(.dark)
            .background(WindowTracker { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 140, y: 150, width: 860, height: 600),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func anchors() -> [RealitySurfaceAnchor] { all(host).compactMap { $0 as? RealitySurfaceAnchor } }
        func findTarget(_ page: Page) -> NavigationButton.Button? {
            all(host).compactMap { $0 as? NavigationButton.Button }.first { $0.toolTip == page.rawValue }
        }
        func target(_ page: Page) throws -> NavigationButton.Button { try XCTUnwrap(findTarget(page)) }
        let limit = ContinuousClock.now + .seconds(3)
        while (window.alphaValue == 0 || anchors().filter { $0.style.rowOffset != nil && $0.textureImage != nil }.count != 2 ||
               findTarget(.profiles) == nil) && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
        let stage = try XCTUnwrap(all(host).compactMap { $0 as? RealityStageView }.first)
        let output = ProcessInfo.processInfo.environment["V2RAYM_HOVER_RENDER_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        func capture(_ name: String) throws {
            guard let output else { return }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            child.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
            try child.run(); child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
        }
        let rows = anchors().filter { $0.style.rowOffset != nil && $0.textureImage != nil }
        XCTAssertEqual(rows.count, 2)
        let rowImages = rows.map(\.textureImage)
        try capture("home-idle")
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (page, name) in [(Page.settings, "disc"), (.profiles, "node"), (.logs, "recent")] {
            let button = try target(page)
            let original = button.convert(button.bounds, to: nil)
            let inStage = button.convert(button.bounds, to: stage)
            let middle = CGPoint(x: inStage.midX, y: inStage.midY)
            func currentSolid() throws -> RealitySurfaceAnchor { try XCTUnwrap(anchors().first {
                ($0.style.shape == .dashboard(.dial) || $0.style.shape == .dashboard(.card)) &&
                $0.convert($0.bounds, to: stage).contains(middle)
            }) }
            func pointer(_ local: NSPoint) throws {
                let activeButton = try target(page)
                let point = activeButton.convert(local, to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
                activeButton.mouseMoved(with: event)
            }
            if page == .settings {
                try pointer(NSPoint(x: 0.1, y: 0.1))
                XCTAssertEqual(try currentSolid().style.faceScale, 1)
            }
            try pointer(NSPoint(x: button.bounds.midX, y: button.bounds.midY))
            if reduced { try await Task.sleep(for: .milliseconds(200)) }
            let enterDeadline = ContinuousClock.now + .seconds(2)
            while abs(try currentSolid().style.faceScale - (reduced ? 1 : 1.032)) > 0.0001 && ContinuousClock.now < enterDeadline {
                try await Task.sleep(for: .milliseconds(16))
            }
            let anchor = try currentSolid()
            XCTAssertEqual(anchor.style.faceScale, reduced ? 1 : 1.032, accuracy: 0.002, name)
            XCTAssertEqual(anchor.style.angle, reduced ? 0 : -8, accuracy: 0.1, name)
            XCTAssertEqual(anchor.style.tilt, reduced ? 0 : 5, accuracy: 0.1, name)
            let activeButton = try target(page)
            XCTAssertEqual(activeButton.convert(activeButton.bounds, to: nil), original, "The clickable rectangle moved for " + name)
            let centerInWindow = NSPoint(x: original.midX, y: original.midY)
            let hit = host.hitTest(host.superview!.convert(centerInWindow, from: nil))
            XCTAssertTrue(hit === activeButton, "The original hit target lost the pointer for " + name)
            let model = try XCTUnwrap(stage.owner.root.findEntity(named: "surface-" + anchor.surfaceID.uuidString))
            XCTAssertEqual(model.scale.x, Float(anchor.style.faceScale), accuracy: 0.002)
            XCTAssertFalse(anchors().contains { $0 !== anchor && $0.style.shape == .dashboard(.card) && $0.style.faceScale > 1 })
            XCTAssertTrue(rows.indices.allSatisfy { rows[$0].textureImage === rowImages[$0] })
            XCTAssertFalse(anchor.style.highlighted)
            try capture("home-" + name)
            try pointer(NSPoint(x: -5, y: -5))
            let exitDeadline = ContinuousClock.now + .seconds(2)
            while abs(try currentSolid().style.faceScale - 1) > 0.0001 && ContinuousClock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(16))
            }
            XCTAssertEqual(try currentSolid().style.faceScale, 1, accuracy: 0.002, name)
        }
    }
}
