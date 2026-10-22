import AppKit
import XCTest
@testable import V2rayMKit

final class NativeLogDocumentTests: XCTestCase {
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
