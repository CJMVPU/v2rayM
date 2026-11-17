import XCTest
import AppKit
@testable import V2rayM

@MainActor final class WindowMinimizeCoordinatorTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil)
        return window
    }
    func testFreezesBeforeImmediateMinimizeAndHandsOffLatch() {
        let window = window()
        var state: DashboardVisibilityState?
        let watcher = DashboardVisibilityObserver.Watcher { state = $0 }
        window.contentView = watcher
        let clock = DashboardDisplayClock()
        clock.attach(window: window, enabled: true)
        let freeze = NotificationCenter.default.addObserver(forName: .dashboardWillFreeze, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { clock.freeze() }
        }
        var calls = 0, requestReturned = false
        let coordinator = WindowMinimizeCoordinator { target in
            calls += 1
            XCTAssertFalse(requestReturned, "No delayed task/run-loop turn before AppKit")
            XCTAssertTrue(target === window)
            XCTAssertEqual(state?.preparingToMinimize, true)
            XCTAssertFalse(clock.isRunning)
            NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: target)
        }
        defer { NotificationCenter.default.removeObserver(freeze); clock.stop(); watcher.stop(); window.close() }
        coordinator.request(window); requestReturned = true
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(state?.preparingToMinimize, false)
        XCTAssertEqual(state?.minimizing, true)
        watcher.thaw(); clock.attach(window: window, enabled: true)
        XCTAssertFalse(clock.isRunning)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        XCTAssertEqual(state?.minimizing, false)
    }
    func testReentrantRequestIsIgnoredAndNoOpReleasesLatch() {
        let window = window()
        var calls = 0
        var coordinator: WindowMinimizeCoordinator!
        coordinator = WindowMinimizeCoordinator { target in calls += 1; coordinator.request(target) }
        defer { window.close() }
        coordinator.request(window)
        XCTAssertEqual(calls, 1); XCTAssertFalse(coordinator.isPreparing(window))
        coordinator.request(window)
        XCTAssertEqual(calls, 2)
    }
    func testSynchronousCancellationOrHiddenWindowPreventsAction() {
        for cancel in [true, false] {
            let window = window()
            var calls = 0
            let coordinator = WindowMinimizeCoordinator { _ in calls += 1 }
            let observer = NotificationCenter.default.addObserver(forName: .windowMinimizePreparationBegan, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if cancel { coordinator.cancel(for: window) } else { window.orderOut(nil) }
                }
            }
            coordinator.request(window)
            XCTAssertEqual(calls, 0); XCTAssertFalse(coordinator.isPreparing(window))
            NotificationCenter.default.removeObserver(observer); window.close()
        }
    }
    func testAlreadyHiddenWindowDoesNotPrepare() {
        let window = window(); window.orderOut(nil)
        let coordinator = WindowMinimizeCoordinator { _ in XCTFail("Hidden window must not minimize") }
        coordinator.request(window)
        XCTAssertFalse(coordinator.isPreparing(window)); window.close()
    }
    func testOtherWindowDoesNotCancelPreparation() {
        let first = window(), second = window()
        var calls = 0
        let coordinator = WindowMinimizeCoordinator { _ in calls += 1 }
        let observer = NotificationCenter.default.addObserver(forName: .windowMinimizePreparationBegan, object: first, queue: .main) { _ in
            MainActor.assumeIsolated { coordinator.cancel(for: second); XCTAssertTrue(coordinator.isPreparing(first)) }
        }
        defer { NotificationCenter.default.removeObserver(observer); first.close(); second.close() }
        coordinator.request(first); XCTAssertEqual(calls, 1)
    }
}
