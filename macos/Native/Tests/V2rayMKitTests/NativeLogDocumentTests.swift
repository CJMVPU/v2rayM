import AppKit
import XCTest
@testable import V2rayMKit

final class NativeLogDocumentTests: XCTestCase {
    private func rows(_ range: ClosedRange<Int>) -> [LogEntry] {
        range.map { LogEntry(timestamp: "fixture", source: "core", message: "row \($0) " + String(repeating: "wide-log-\($0)-", count: 40), sequence: Int64($0)) }
    }
    @MainActor private func renderIfRequested(_ document: NativeLogDocument, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_LOG_SCROLL_RENDER_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = document.scrollView
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
    @MainActor func testAutomaticRunLoopAnimationCompletes() async throws {
        let document = NativeLogDocument(now: { ProcessInfo.processInfo.systemUptime }, reduceMotion: { false })
        document.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 140)
        document.update(rows(1...80)); document.update(rows(1...90))
        XCTAssertTrue(document.isAnimatingTail)
        for _ in 0..<40 where document.isAnimatingTail { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(document.scrollView.contentView.bounds.maxY, document.scrollView.documentView!.frame.maxY, accuracy: 1)
    }
    @MainActor func testTailAppendAnimatesWithoutJumpingAndPreservesHorizontalOffset() throws {
        var time: TimeInterval = 100
        let document = NativeLogDocument(now: { time }, reduceMotion: { false }, automaticallyTick: false)
        let scroll = document.scrollView
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 140)
        document.update(rows(1...80))
        scroll.contentView.scroll(to: NSPoint(x: 180, y: scroll.contentView.bounds.origin.y))
        let before = scroll.contentView.bounds.origin.y
        try renderIfRequested(document, name: "scroll-before")
        document.update(rows(1...90))
        let bottom = scroll.documentView!.frame.height - scroll.contentView.bounds.height
        XCTAssertTrue(document.isAnimatingTail)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, before, accuracy: 1)
        time += 0.11; document.advanceTailAnimation()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, before)
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, bottom)
        try renderIfRequested(document, name: "scroll-middle")
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 180, accuracy: 1)
        time += 0.2; document.advanceTailAnimation()
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, bottom, accuracy: 1)
        try renderIfRequested(document, name: "scroll-after")
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 180, accuracy: 1)
    }
    @MainActor func testUserScrollInterruptsAnimationAndLaterAppendsDoNotStealHistory() throws {
        var time: TimeInterval = 100
        let document = NativeLogDocument(now: { time }, reduceMotion: { false }, automaticallyTick: false)
        let scroll = document.scrollView
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 140)
        document.update(rows(1...80)); document.update(rows(1...90))
        time += 0.06; document.advanceTailAnimation()
        XCTAssertTrue(document.isAnimatingTail)
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 300))
        XCTAssertFalse(document.isAnimatingTail)
        time += 1; document.advanceTailAnimation()
        document.update(rows(1...100))
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 300, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 120, accuracy: 1)
    }
    @MainActor func testHistoryJustAboveBottomDoesNotAutoFollow() throws {
        let document = NativeLogDocument(now: { 100 }, reduceMotion: { false }, automaticallyTick: false)
        let scroll = document.scrollView
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 140)
        document.update(rows(1...80))
        let historyPosition = scroll.contentView.bounds.origin.y - 12
        scroll.contentView.scroll(to: NSPoint(x: 0, y: historyPosition))
        document.update(rows(1...90))
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, historyPosition, accuracy: 1)
    }
    @MainActor func testRapidAppendsRetargetOneAnimationAndEvictionCompensatesItsPosition() throws {
        var time: TimeInterval = 100
        let document = NativeLogDocument(now: { time }, reduceMotion: { false }, automaticallyTick: false)
        let scroll = document.scrollView
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 140)
        document.update(rows(1...80)); document.update(rows(1...90))
        time += 0.06; document.advanceTailAnimation()
        let partial = scroll.contentView.bounds.origin.y
        document.update(rows(1...95))
        XCTAssertTrue(document.isAnimatingTail)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, partial, accuracy: 1)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let layout = try XCTUnwrap(text.layoutManager)
        let firstSurvivor = (text.string as NSString).range(of: "row 2 ").location
        let removedHeight = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: firstSurvivor), effectiveRange: nil).minY
        document.update(rows(2...96))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, partial - removedHeight, accuracy: 1)
        XCTAssertTrue(document.isAnimatingTail)
        time += 1; document.advanceTailAnimation()
        XCTAssertEqual(scroll.contentView.bounds.maxY, text.frame.maxY, accuracy: 1)
        XCTAssertFalse(document.isAnimatingTail)
    }
    @MainActor func testReduceMotionDisablesAnimationAndCanFinishAnExistingTween() throws {
        var time: TimeInterval = 100
        var reduced = true
        let document = NativeLogDocument(now: { time }, reduceMotion: { reduced }, automaticallyTick: false)
        let scroll = document.scrollView
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 140)
        document.update(rows(1...80)); document.update(rows(1...90))
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView!.frame.maxY, accuracy: 1)
        reduced = false; document.update(rows(1...100))
        XCTAssertTrue(document.isAnimatingTail)
        reduced = true; time += 0.03; document.advanceTailAnimation()
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView!.frame.maxY, accuracy: 1)
    }
    @MainActor func testTeardownStopsPendingAnimationWithoutMovingTheViewport() throws {
        var time: TimeInterval = 100
        let document = NativeLogDocument(now: { time }, reduceMotion: { false }, automaticallyTick: false)
        document.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 140)
        document.update(rows(1...80)); document.update(rows(1...90))
        let position = document.scrollView.contentView.bounds.origin
        document.stopFollowingAnimation()
        time += 1; document.advanceTailAnimation()
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(document.scrollView.contentView.bounds.origin, position)
    }
    @MainActor func testTrimmingMultilineEntryKeepsTheSameVisibleContent() throws {
        let document = NativeLogDocument()
        let scroll = document.scrollView
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 120)
        func entry(_ sequence: Int, _ message: String) throws -> LogEntry {
            try JSONDecoder().decode(LogEntry.self, from: JSONSerialization.data(withJSONObject:
                ["timestamp": "fixture", "source": "core", "sequence": sequence, "message": message]))
        }
        let first = try entry(0, "old first\nold second\nold third")
        let remaining = try (1...100).map { try entry($0, "kept line \($0)") }
        document.update([first] + remaining)
        let text = scroll.documentView as! NSTextView
        let layout = text.layoutManager!
        let start = (text.string as NSString).range(of: "kept line 1").location
        let removedHeight = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        let before = scroll.contentView.bounds.origin.y
        document.update(remaining)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, before - removedHeight, accuracy: 1)
        XCTAssertFalse(text.string.contains("old second"))
        XCTAssertTrue(text.string.hasPrefix("kept line 1\n"))
    }
    @MainActor func testLongLinesScrollHorizontallyWithoutScrollbarsAndKeepPositionOnAppend() throws {
        let document = NativeLogDocument()
        let scroll = document.scrollView
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        func entry(_ sequence: Int) throws -> LogEntry {
            let payload: [String: Any] = ["timestamp": "fixture", "source": "core", "sequence": sequence,
                "message": "line \(sequence) " + String(repeating: "horizontal-log-text-", count: 30)]
            return try JSONDecoder().decode(LogEntry.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let first = try entry(1)
        document.update([first])
        XCTAssertGreaterThan(scroll.documentView!.frame.width, scroll.contentView.bounds.width)
        XCTAssertFalse(scroll.hasHorizontalScroller); XCTAssertFalse(scroll.hasVerticalScroller)
        scroll.contentView.scroll(to: NSPoint(x: 180, y: 0))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.x, 0)
        document.update([first, try entry(2)])
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 180, accuracy: 1)
        document.update([first, try entry(2)])
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 180, accuracy: 1)
        XCTAssertTrue((scroll.documentView as! NSTextView).string.contains("line 1"))
    }
}
