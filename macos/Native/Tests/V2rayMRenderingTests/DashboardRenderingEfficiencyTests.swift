import XCTest
import AppKit
import SwiftUI
@testable import V2rayM

@MainActor private final class EfficiencyFixture: ObservableObject {
    @Published var angle = 0.0
    var fronts = 0
    var backs = 0
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

    @MainActor func testOcclusionWaitsAndQuickReturnCancelsPendingPause() async throws {
        let coordinator = DashboardVisibilityCoordinator(departureDelay: 0.12, returnDelay: 0.05, catchUpDuration: 0.04)
        let visible = DashboardVisibilityState(windowVisible: true, occluded: false)
        var occluded = visible; occluded.occluded = true
        coordinator.update(visible)
        XCTAssertEqual(coordinator.phase, .live)
        coordinator.update(occluded)
        XCTAssertEqual(coordinator.phase, .departing)
        XCTAssertTrue(coordinator.phase.rendersMotion)
        XCTAssertFalse(coordinator.phase.acceptsData)
        try await Task.sleep(for: .milliseconds(30))
        coordinator.update(visible)
        XCTAssertEqual(coordinator.phase, .returning)
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertEqual(coordinator.phase, .catchingUp)
        XCTAssertFalse(coordinator.phase.permitsFlips)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(coordinator.phase, .live, "Cancelled departure must not suspend a restored window")
        coordinator.update(occluded)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(coordinator.phase, .suspended)
        coordinator.stop()
    }

    @MainActor func testStageManagerThumbnailCanRemainVisibleWhileInactive() async throws {
        let coordinator = DashboardVisibilityCoordinator(departureDelay: 0.04, returnDelay: 0.02, catchUpDuration: 0.02)
        var state = DashboardVisibilityState(windowVisible: true, occluded: false)
        coordinator.update(state)
        state.appActive = false; coordinator.update(state)
        XCTAssertEqual(coordinator.phase, .departing)
        XCTAssertFalse(state.permitsRendering)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(coordinator.phase, .suspended)
        state.appActive = true; coordinator.update(state)
        XCTAssertEqual(coordinator.phase, .returning)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(coordinator.phase, .live)
        coordinator.stop()
    }

    @MainActor func testHardBlockersCancelGraceAndCannotBeOverriddenByLateTasks() async throws {
        for key in [\DashboardVisibilityState.minimized, \.appHidden, \.locked, \.sleeping] {
            let coordinator = DashboardVisibilityCoordinator(departureDelay: 0.04, returnDelay: 0.04, catchUpDuration: 0.02)
            var state = DashboardVisibilityState(windowVisible: true, occluded: false)
            coordinator.update(state); state.occluded = true; coordinator.update(state)
            state.occluded = false; coordinator.update(state)
            state[keyPath: key] = true; coordinator.update(state)
            XCTAssertEqual(coordinator.phase, .suspended)
            try await Task.sleep(for: .milliseconds(90))
            XCTAssertEqual(coordinator.phase, .suspended)
            coordinator.stop()
        }
    }

    @MainActor func testFrozenPresentationIgnoresBackgroundUpdatesAndReadsLatestOnResume() async throws {
        let model = AppModel()
        let source = DashboardPresentationSource(model: model)
        source.setEnabled(true)
        model.connecting = true
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(source.snapshot.connecting)
        source.setEnabled(false)
        let frozenDate = source.snapshot.now
        for _ in 0..<100 { model.connecting.toggle() }
        model.connecting = false
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(source.snapshot.now, frozenDate)
        XCTAssertTrue(source.snapshot.connecting)
        source.setEnabled(true)
        XCTAssertFalse(source.snapshot.connecting)
        XCTAssertGreaterThan(source.snapshot.now, frozenDate)
        source.setEnabled(false)
    }
}
