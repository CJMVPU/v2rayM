import XCTest
import AppKit
@testable import V2rayM

@MainActor final class WindowMinimizeCoordinatorTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    func testFreezesSynchronouslyThenYieldsBeforeSingleMinimizeAndHandsOffLatch() async throws {
        let window = window()
        var state: DashboardVisibilityState?
        let watcher = DashboardVisibilityObserver.Watcher { state = $0 }
        window.contentView = watcher
        let clock = DashboardDisplayClock()
        clock.attach(window: window, enabled: true)
        let freeze = NotificationCenter.default.addObserver(forName: .dashboardWillFreeze, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { clock.freeze() }
        }
        var calls = 0
        let started = ProcessInfo.processInfo.systemUptime
        let coordinator = WindowMinimizeCoordinator { target in
            calls += 1
            XCTAssertTrue(target === window)
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.5)
            XCTAssertEqual(state?.preparingToMinimize, true)
            XCTAssertFalse(clock.isRunning)
            NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: target)
        }
        defer {
            coordinator.cancel(); NotificationCenter.default.removeObserver(freeze)
            clock.stop(); watcher.stop(); window.close()
        }
        coordinator.request(window)
        XCTAssertEqual(state?.preparingToMinimize, true)
        XCTAssertFalse(state?.permitsRendering ?? true)
        XCTAssertFalse(clock.isRunning, "Stop display callbacks in the click's turn, before sleeping")
        coordinator.request(window)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(state?.preparingToMinimize, true)
        watcher.thaw()
        clock.attach(window: window, enabled: true)
        XCTAssertFalse(clock.isRunning, "Intermediate updates cannot thaw the preparation interval")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, 0, "The main actor must remain available during the gap")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(calls, 1, "Repeated clicks must not queue repeated minimizations")
        XCTAssertEqual(state?.preparingToMinimize, false)
        XCTAssertEqual(state?.minimizing, true, "AppKit owns the freeze after the preparation gap")
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        XCTAssertEqual(state?.minimizing, false)
    }

    func testCancellationPreventsLateMinimizeAndAllowsNewRequest() async throws {
        let window = window()
        var calls = 0
        let coordinator = WindowMinimizeCoordinator(preparationDelay: 0.04) { _ in calls += 1 }
        defer { coordinator.cancel(); window.close() }
        coordinator.request(window)
        coordinator.cancel(for: window)
        XCTAssertFalse(coordinator.isPreparing(window))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 0)
        coordinator.request(window)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(coordinator.isPreparing(window), "A rejected/no-op system minimize must release preparation")
    }

    func testCloseHideResignRestoreAndExternalMinimizeCancelPendingAction() async throws {
        for name in [NSWindow.willCloseNotification, NSApplication.willHideNotification,
                     NSApplication.willResignActiveNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willMiniaturizeNotification] {
            let window = window()
            var calls = 0
            let coordinator = WindowMinimizeCoordinator(preparationDelay: 0.03) { _ in calls += 1 }
            coordinator.request(window)
            XCTAssertTrue(coordinator.isPreparing(window))
            NotificationCenter.default.post(name: name, object: window)
            XCTAssertFalse(coordinator.isPreparing(window), name.rawValue)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(calls, 0, name.rawValue)
            coordinator.cancel(); window.close()
        }
    }

    func testHiddenWindowIsRecheckedAfterDelay() async throws {
        let window = window()
        var calls = 0
        let coordinator = WindowMinimizeCoordinator(preparationDelay: 0.03) { _ in calls += 1 }
        defer { coordinator.cancel(); window.close() }
        coordinator.request(window)
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(coordinator.isPreparing(window))
        coordinator.request(window)
        XCTAssertFalse(coordinator.isPreparing(window))
    }

    func testOtherWindowDoesNotCancelPreparation() async throws {
        let first = window(), second = window()
        var calls = 0
        let coordinator = WindowMinimizeCoordinator(preparationDelay: 0.04) { _ in calls += 1 }
        defer { coordinator.cancel(); first.close(); second.close() }
        coordinator.request(first)
        coordinator.cancel(for: second)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: second)
        XCTAssertTrue(coordinator.isPreparing(first))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 1)
    }
}
