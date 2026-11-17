import XCTest
import AppKit
@testable import V2rayMKit
@testable import V2rayM

@MainActor final class RecentRowFlipTests: XCTestCase {
    private func face(_ group: Int, _ index: Int = 1) throws -> RecentRowFace {
        RecentRowFace(try XCTUnwrap(GlobeConnection.parse(LogEntry(timestamp: "2026-11-17T00:00:00Z", source: "core",
            message: "from tcp:127.0.0.1:1234 accepted tcp:192.0.\(group).\(index):443 [socks >> proxy]", sequence: 1))))
    }
    private func fixture(count: Int = 7, scale: Double = 0.06) throws -> (NSWindow, RecentRowFlipScheduler, [CachedRecentRowView]) {
        AppFont.register()
        let scheduler = RecentRowFlipScheduler(timingScale: scale, seed: 9017)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 260, height: 210), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect); window.contentView = host
        let rows = try (0..<count).map { index in
            let view = CachedRecentRowView(slot: index, scheduler: scheduler)
            view.frame = CGRect(x: 0, y: index * 28, width: 260, height: 24)
            host.addSubview(view); view.layout()
            view.update(try face(1, index), motion: true, flips: true, reduced: false)
            return view
        }
        window.orderFront(nil)
        return (window, scheduler, rows)
    }
    func testUnchangedFacesReuseBitmapAndScheduleNothing() throws {
        let (window, scheduler, rows) = try fixture(count: 1)
        defer { rows.forEach { $0.stop() }; window.close() }
        let before = rows[0].bitmapBuilds
        for _ in 0..<600 { rows[0].update(try face(1, 0), motion: true, flips: true, reduced: false) }
        XCTAssertEqual(rows[0].bitmapBuilds, before)
        XCTAssertEqual(scheduler.activeCount, 0); XCTAssertEqual(scheduler.pendingCount, 0)
    }
    func testNextFaceIsPreparedHiddenWithoutChangingVisibleContent() throws {
        let (window, scheduler, rows) = try fixture(count: 1)
        defer { rows.forEach { $0.stop() }; window.close() }
        rows[0].update(try face(2), motion: true, flips: true, reduced: false)
        rows[0].startFlip(duration: 1)
        XCTAssertEqual(rows[0].displayed, try face(1, 0))
        XCTAssertTrue(rows[0].turning)
        XCTAssertEqual(rows[0].preparedFace, try face(2), "The next face must be prepared without replacing displayed content")
        XCTAssertGreaterThanOrEqual(rows[0].bitmapBuilds, 2)
        XCTAssertLessThanOrEqual(scheduler.activeCount, 2)
    }
    func testConnectionMovingBetweenSlotsReusesSharedFace() throws {
        let (window, scheduler, rows) = try fixture(count: 2)
        defer { rows.forEach { $0.stop() }; window.close() }
        let builds = rows.map(\.bitmapBuilds).reduce(0, +)
        rows[0].update(try face(8), motion: true, flips: false, reduced: true)
        rows[1].update(try face(8), motion: true, flips: false, reduced: true)
        XCTAssertEqual(rows.map(\.bitmapBuilds).reduce(0, +) - builds, 1)
        XCTAssertEqual(scheduler.activeCount, 0)
    }
    func testTwoTurnBudgetIndependentOrderAndLatestWins() async throws {
        let (window, scheduler, rows) = try fixture()
        defer { rows.forEach { $0.stop() }; window.close() }
        var starts: [Int] = []; scheduler.onStart = { starts.append($0) }
        for row in rows { row.update(try face(2, row.slot), motion: true, flips: true, reduced: false) }
        try await Task.sleep(for: .milliseconds(45))
        for group in 3...20 {
            for row in rows { row.update(try face(group, row.slot), motion: true, flips: true, reduced: false) }
        }
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertLessThanOrEqual(scheduler.peakConcurrent, 2)
        XCTAssertGreaterThan(starts.count, 0)
        XCTAssertNotEqual(starts, Array(0..<7), "Do not use slot order as a wave")
        XCTAssertEqual(Set(starts).count, 7)
        XCTAssertLessThanOrEqual(starts.count, 10, "Intermediate values must not queue turns")
        for row in rows {
            XCTAssertEqual(row.displayed, try face(20, row.slot))
            XCTAssertLessThanOrEqual(row.bitmapBuilds, 4, "Do not rasterize every pending update")
        }
        XCTAssertEqual(scheduler.activeCount, 0); XCTAssertEqual(scheduler.pendingCount, 0)
    }
    func testFreezeCancelsTurnsAndLateUpdatesThenThawsToLatest() async throws {
        let (window, scheduler, rows) = try fixture(scale: 0.2)
        defer { rows.forEach { $0.stop() }; window.close() }
        for row in rows { row.update(try face(2, row.slot), motion: true, flips: true, reduced: false) }
        try await Task.sleep(for: .milliseconds(130))
        NotificationCenter.default.post(name: .dashboardWillFreeze, object: window)
        let builds = rows.map(\.bitmapBuilds)
        for row in rows { row.update(try face(9, row.slot), motion: true, flips: true, reduced: false) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(scheduler.activeCount, 0); XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(rows.map(\.bitmapBuilds), builds)
        XCTAssertTrue(rows.allSatisfy { $0.frozen && !$0.turning })
        var starts = 0; scheduler.onStart = { _ in starts += 1 }
        NotificationCenter.default.post(name: .dashboardDidThaw, object: window)
        for row in rows { row.update(try face(9, row.slot), motion: true, flips: false, reduced: false) }
        try await Task.sleep(for: .milliseconds(160))
        for row in rows { XCTAssertEqual(row.displayed, try face(9, row.slot)); XCTAssertFalse(row.recovering) }
        XCTAssertEqual(starts, 0, "Restoration must not replay queued flips")
    }
    func testReduceMotionAndDismantleCancelPendingTurns() async throws {
        let (window, scheduler, rows) = try fixture()
        defer { rows.forEach { $0.stop() }; window.close() }
        for row in rows {
            row.update(try face(2, row.slot), motion: true, flips: true, reduced: false)
            row.update(try face(3, row.slot), motion: true, flips: true, reduced: true)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(scheduler.peakConcurrent, 0)
        for row in rows { XCTAssertEqual(row.displayed, try face(3, row.slot)) }
        for row in rows { row.update(try face(4, row.slot), motion: true, flips: true, reduced: false); row.stop() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(scheduler.activeCount, 0); XCTAssertEqual(scheduler.pendingCount, 0)
    }
}
