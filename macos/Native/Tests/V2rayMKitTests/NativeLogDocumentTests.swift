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
    @MainActor func testWheelAccumulatesBothAxesAndClampsAtDocumentEdge() {
        let document = NativeLogDocument()
        let scroll = document.scrollView
        scroll.frame = CGRect(x: 0, y: 0, width: 500, height: 120)
        document.update(rows(1...80))
        let wheel = SmoothWheelScroll(), clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 10, y: 150))
        XCTAssertTrue(wheel.move(in: scroll, by: CGPoint(x: 40, y: 70), at: 1))
        wheel.advance(at: 1.04)
        XCTAssertGreaterThan(clip.bounds.minY, 150)
        XCTAssertLessThan(clip.bounds.minY, 220)
        XCTAssertTrue(wheel.move(in: scroll, by: CGPoint(x: 25, y: 30), at: 1.04))
        wheel.advance(at: 1.3)
        XCTAssertEqual(clip.bounds.origin, CGPoint(x: 75, y: 250))
        XCTAssertFalse(wheel.isMoving)
        wheel.move(in: scroll, by: CGPoint(x: -500, y: -900), at: 2)
        wheel.advance(at: 3)
        XCTAssertEqual(clip.bounds.origin, .zero)
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
        // Verify that the first horizontal scroll paints glyphs at the tail.
        // TextKit can return a nonempty character range while painting a blank view.
        scroll.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let background = bitmap.colorAt(x: 10, y: 10)
        var ink = 0
        for y in stride(from: 20, to: bitmap.pixelsHigh - 20, by: 4) {
            for x in stride(from: 20, to: bitmap.pixelsWide - 20, by: 8) where bitmap.colorAt(x: x, y: y) != background {
                ink += 1
            }
        }
        XCTAssertGreaterThan(ink, 100)
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
        let text = document.textView
        let layout = try XCTUnwrap(text.layoutManager)
        let firstSurvivor = (text.string as NSString).range(of: "row 2 ").location
        let removedHeight = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: firstSurvivor), effectiveRange: nil).minY
        document.update(rows(2...96))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, partial - removedHeight, accuracy: 1)
        XCTAssertTrue(document.isAnimatingTail)
        time += 1; document.advanceTailAnimation()
        XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView!.frame.maxY, accuracy: 1)
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
    @MainActor func testHiddenLogTailRestoresOnceAndNeverMovesAHistoryReader() throws {
        var visible = true
        let document = NativeLogDocument(now: { 1 }, reduceMotion: { false }, automaticallyTick: false,
                                         canPresent: { _ in visible })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = document.scrollView
        window.contentView = scroll
        let clip = scroll.contentView
        func changeVisibility(_ value: Bool) {
            visible = value
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        document.update(rows(1...80))
        clip.scroll(to: NSPoint(x: 70, y: clip.bounds.minY))
        document.update(rows(1...85))
        XCTAssertTrue(document.isAnimatingTail)
        let original = clip.bounds.origin
        changeVisibility(false)
        document.update(rows(1...95))
        document.update(rows(1...105))
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(clip.bounds.origin, original)
        XCTAssertTrue(document.textView.string.contains("row 105 "))
        changeVisibility(true)
        XCTAssertFalse(document.isAnimatingTail)
        XCTAssertEqual(clip.bounds.maxY, scroll.documentView!.bounds.maxY, accuracy: 1)
        XCTAssertEqual(clip.bounds.minX, original.x)
        let selected = (document.textView.string as NSString).range(of: "row 53 ")
        document.textView.setSelectedRange(selected)
        clip.scroll(to: NSPoint(x: 95, y: 400))
        changeVisibility(false)
        document.update(rows(2...106))
        let reading = clip.bounds.origin
        XCTAssertLessThan(reading.y, 400)
        changeVisibility(true)
        XCTAssertEqual(clip.bounds.origin, reading)
        XCTAssertEqual((document.textView.string as NSString).substring(with: document.textView.selectedRange()), "row 53 ")
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
        let text = document.textView
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
    @MainActor func testLargeDocumentLaysOutTheRequestedViewportAndRetainsNativeSelection() throws {
        let document = NativeLogDocument(now: { 0 }, reduceMotion: { true }, automaticallyTick: false)
        let scroll = document.scrollView
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 120)
        func row(_ index: Int) -> LogEntry {
            let detail = index.isMultiple(of: 2) ? "" : String(repeating: "宽日志🙂 / ", count: 12)
            return LogEntry(timestamp: "fixture", source: "core", message: detail + "日志 🚦 row[\(index)]", sequence: Int64(index))
        }
        let entries = (0..<10_000).map(row)
        document.update(entries)
        let text = document.textView
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        let paragraph = try XCTUnwrap(text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        func visibleText() -> String {
            let bounds = text.bounds.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
            let glyphs = manager.glyphRange(forBoundingRect: bounds, in: container)
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            return (text.string as NSString).substring(with: chars)
        }
        XCTAssertTrue(visibleText().contains("row[9999]"))
        for index in [5_000, 0, 8_300, 312, 9_950] {
            let y = CGFloat(index) * paragraph.minimumLineHeight + text.textContainerInset.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            XCTAssertEqual(scroll.contentView.bounds.minY, y, accuracy: 1)
            XCTAssertTrue(visibleText().contains("row[\(index)]"), "Missing requested row \(index)")
        }
        // AppKit's native caret placement must use the scrolled lines even
        // though the editor's local bounds have a zero origin and limited size.
        let point = NSPoint(x: 18, y: paragraph.minimumLineHeight * 1.5)
        let hit = text.characterIndexForInsertion(at: point)
        let value = text.string as NSString
        XCTAssertTrue(value.substring(with: value.lineRange(for: NSRange(location: hit, length: 0))).contains("row[9951]"))
        let selected = "row[9951]\n日志 🚦 row[9952]"
        text.setSelectedRange((text.string as NSString).range(of: selected))
        document.update(Array(entries.dropFirst()) + [row(10_000)])
        XCTAssertTrue(visibleText().contains("row[9950]"))
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), selected)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), selected)
        XCTAssertEqual(text.accessibilitySelectedText(), selected)
        XCTAssertEqual(text.accessibilityNumberOfCharacters(), (text.string as NSString).length)
        XCTAssertTrue((text.accessibilityValue() as? String)?.hasSuffix("row[10000]\n") == true)
    }

    @MainActor func testFIFOHistoryCanSkipDeliveriesReplaceItsEntireWindowAndRestartSequenceNumbers() {
        let document = NativeLogDocument()
        document.scrollView.frame = CGRect(x: 0, y: 0, width: 600, height: 140)
        var epoch = UUID(), history = RollingLogBuffer(maximumLines: 3)
        func publish() {
            document.update(history.entries, position: .init(epoch: epoch, headOffset: history.headOffset))
            XCTAssertEqual(document.textView.string, history.entries.map { $0.message + "\n" }.joined())
        }
        _ = history.append(rows(1...3))
        publish()
        _ = history.append(rows(4...5))
        _ = history.append(rows(6...9))
        XCTAssertEqual(history.headOffset, 6)
        publish()
        _ = history.append(rows(10...10))
        publish()
        epoch = UUID()
        history = RollingLogBuffer(maximumLines: 3)
        publish()
        let replacement = LogEntry(timestamp: "restart", source: "core", message: "new run", sequence: 1)
        _ = history.append([replacement])
        publish()
        var arbitrary = replacement
        arbitrary.message = "edited"
        document.update([arbitrary])
        XCTAssertEqual(document.textView.string, "edited\n")
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
        XCTAssertTrue((document.textView).string.contains("line 1"))
    }
}
