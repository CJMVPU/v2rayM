import XCTest
import AppKit
import SwiftUI
@testable import V2rayM

@MainActor private final class EfficiencyFixture: ObservableObject {
    @Published var angle = 0.0
    @Published var visible = true
    @Published var value = 1
    var fronts = 0
    var backs = 0
    var currentFaces = 0
    var displayed: [Int] = []
}
private struct SurfaceFixture: View {
    @ObservedObject var state: EfficiencyFixture
    var body: some View {
        DashboardSolidSurface(angle: state.angle, kind: .card,
            front: Text("front").frame(width: 200, height: 100)
                .onAppear { state.fronts += 1 },
            back: Text("back").frame(width: 200, height: 100)
                .onAppear { state.backs += 1 })
    }
}
private struct GateFixture: View {
    @ObservedObject var state: EfficiencyFixture
    var body: some View {
        DashboardRenderGate(visible: state.visible) {
            DashboardDataCard(value: state.value, idle: 0, active: true, ready: true, slot: 0) { value, _ in
                Text(String(value)).frame(width: 200, height: 100)
                    .onAppear { state.currentFaces += 1; state.displayed.append(value) }
                    .onDisappear { state.currentFaces -= 1 }
                    .onChange(of: value) { _, value in state.displayed.append(value) }
            }
        }.frame(width: 200, height: 100)
    }
}
final class DashboardRenderingEfficiencyTests: XCTestCase {
    func testEveryVisibilityBlockerSuspendsRendering() {
        let visible = DashboardVisibilityState(windowVisible: true, occluded: false)
        XCTAssertTrue(visible.permitsRendering)
        for key in [\DashboardVisibilityState.minimized, \.occluded, \.appHidden, \.locked, \.sleeping] {
            var blocked = visible; blocked[keyPath: key] = true
            XCTAssertFalse(blocked.permitsRendering)
        }
        var blocked = visible; blocked.windowVisible = false; XCTAssertFalse(blocked.permitsRendering)
        blocked = visible; blocked.sessionActive = false; XCTAssertFalse(blocked.permitsRendering)
        blocked = visible; blocked.locked = true; blocked.sleeping = false
        XCTAssertFalse(blocked.permitsRendering, "Display wake must not override a still-locked session")
    }

    @MainActor func testRequests120AndAdaptsToScreenCapabilities() {
        for (maximum, expected) in [(120, 120), (144, 120), (60, 60), (48, 48)] {
            let range = DashboardDisplayClock.range(maximum: maximum)
            XCTAssertEqual(range.preferred, Float(expected))
            XCTAssertEqual(range.maximum, Float(expected))
            XCTAssertLessThanOrEqual(range.minimum, range.maximum)
        }
    }

    @MainActor func testFrontExistsOnceAndBackOnlyWhileFacingViewer() async throws {
        let state = EfficiencyFixture()
        let host = NSHostingView(rootView: SurfaceFixture(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.fronts, 1, "Layout must not instantiate a second hidden front subtree")
        XCTAssertEqual(state.backs, 0, "Resting surfaces must not mount the back")
        state.angle = 150
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.fronts, 1, "The front's state must survive turning")
        XCTAssertEqual(state.backs, 1)
        state.angle = 0
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.fronts, 1)
    }

    @MainActor func testHiddenDashboardDropsFacesAndResumesLatestWithoutReplay() async throws {
        let state = EfficiencyFixture()
        let host = NSHostingView(rootView: GateFixture(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.currentFaces, 1)
        state.visible = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.currentFaces, 0, "Invisible windows must release the animated subtree immediately")
        let events = state.displayed.count
        for value in 2...100 { state.value = value }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.displayed.count, events, "Background updates should not instantiate faces or enqueue flips")
        state.visible = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.currentFaces, 1)
        XCTAssertEqual(state.displayed.last, 100, "Resume must show the latest snapshot without replaying intermediate values")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(state.displayed.last, 100)
    }
}
