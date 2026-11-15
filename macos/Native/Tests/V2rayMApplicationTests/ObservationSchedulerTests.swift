import XCTest
import Foundation
@testable import V2rayMApplication

private final class TestClock: NativeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 100)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
    func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

@MainActor private final class SuspendedObservation {
    var continuation: CheckedContinuation<Void, Never>?
    func run() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class ObservationSchedulerTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected observation state")
    }

    func testForcedRefreshCoalescesWhileCanceledRequestStillRuns() async {
        let scheduler = ObservationScheduler(clock: TestClock()), held = SuspendedObservation()
        var events: [String] = []
        scheduler.schedule("profiles", interval: 5, force: false) {
            events.append("old-start")
            await held.run()
            if !Task.isCancelled { events.append("stale-publication") }
            events.append("old-end")
        }
        await waitUntil { held.continuation != nil }
        scheduler.schedule("profiles", interval: 5, force: true) { events.append("intermediate") }
        scheduler.schedule("profiles", interval: 5, force: true) {
            XCTAssertFalse(Task.isCancelled)
            events.append("latest")
        }
        scheduler.schedule("profiles", interval: 5, force: false) { events.append("poll") }
        scheduler.schedule("status", interval: 2, force: false) { events.append("independent") }
        await waitUntil { events.contains("independent") }
        XCTAssertEqual(events, ["old-start", "independent"])
        held.release()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(events, ["old-start", "independent", "old-end", "latest"])
    }

    func testCancelDrainsOldRequestAndDropsQueuedWorkBeforeAllowingReuse() async {
        let scheduler = ObservationScheduler(clock: TestClock()), held = SuspendedObservation()
        var queuedRan = false, drained = false, reused = false
        scheduler.schedule("logs", interval: 30, force: false) { await held.run() }
        await waitUntil { held.continuation != nil }
        scheduler.schedule("logs", interval: 30, force: true) { queuedRan = true }
        scheduler.cancel()
        let drain = Task { await scheduler.waitUntilIdle(); drained = true }
        await Task.yield()
        XCTAssertFalse(drained)
        held.release()
        await drain.value
        XCTAssertTrue(drained); XCTAssertFalse(queuedRan)
        scheduler.schedule("logs", interval: 30, force: false) { reused = true }
        await scheduler.waitUntilIdle()
        XCTAssertTrue(reused)
    }

    func testCancelBeforeStartDoesNotLaunchAnUnneededRequest() async {
        let scheduler = ObservationScheduler(clock: TestClock())
        var ran = false
        scheduler.schedule("logs", interval: 2, force: false) { ran = true }
        scheduler.cancel()
        await scheduler.waitUntilIdle()
        XCTAssertFalse(ran)
    }

    func testIntervalsUseCompletionTimeAndRecoverFromClockRollback() async {
        let clock = TestClock()
        let timed = ObservationScheduler(clock: clock), held = SuspendedObservation()
        var runs = 0
        timed.schedule("routes", interval: 30, force: false) { runs += 1; await held.run() }
        await waitUntil { held.continuation != nil }
        clock.advance(100)
        held.release(); await timed.waitUntilIdle()
        clock.advance(29)
        timed.schedule("routes", interval: 30, force: false) { runs += 1 }
        await timed.waitUntilIdle(); XCTAssertEqual(runs, 1)
        clock.advance(1)
        timed.schedule("routes", interval: 30, force: false) { runs += 1 }
        await timed.waitUntilIdle(); XCTAssertEqual(runs, 2)
        clock.advance(-60)
        timed.schedule("routes", interval: 30, force: false) { runs += 1 }
        await timed.waitUntilIdle(); XCTAssertEqual(runs, 3)
    }
}
