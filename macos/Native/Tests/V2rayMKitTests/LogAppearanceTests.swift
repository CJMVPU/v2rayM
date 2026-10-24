import AppKit
import CoreText
import XCTest
@testable import V2rayMKit

final class LogAppearanceTests: XCTestCase {
    private func entry(_ source: String, _ message: String, sequence: Int64 = 1) -> LogEntry {
        LogEntry(timestamp: "2026-10-24T12:00:00Z", source: source, message: message, sequence: sequence)
    }
    func testLevelsUseExplicitSourceOrTokensWithoutMatchingURLWords() {
        XCTAssertEqual(LogKind.classify(entry("core.start", "Xray started")), .lifecycle)
        XCTAssertEqual(LogKind.classify(entry("core", "core.started")), .lifecycle)
        XCTAssertEqual(LogKind.classify(entry("core", "core.startFailed")), .error)
        XCTAssertEqual(LogKind.classify(entry("core.error", "Could not start")), .error)
        XCTAssertEqual(LogKind.classify(entry("core", "2026/10/24 [Error] outbound failure")), .error)
        XCTAssertEqual(LogKind.classify(entry("core", "[Warning] retry scheduled")), .warning)
        XCTAssertEqual(LogKind.classify(entry("backend.warning", "retry")), .warning)
        XCTAssertEqual(LogKind.classify(entry("core", "[Debug] dial attempt")), .debug)
        XCTAssertEqual(LogKind.classify(entry("core", "[Info] connected")), .info)
        XCTAssertEqual(LogKind.classify(entry("core.start", "[Error] failed to start")), .error)
        XCTAssertEqual(LogKind.classify(entry("core", "accepted tcp:error.example:443 [socks >> proxy]")), .normal)
    }
    @MainActor func testEachRecordRetainsItsColorAcrossAppendAndOldestEviction() throws {
        let document = NativeLogDocument()
        document.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 180)
        let first = entry("core.start", "started", sequence: 1)
        let warning = entry("core", "[Warning] first line\nsecond line", sequence: 2)
        let error = entry("core", "[Error] failed", sequence: 3)
        document.update([first, warning]); document.update([first, warning, error]); document.update([warning, error])
        let text = try XCTUnwrap(document.scrollView.documentView as? NSTextView)
        let storage = try XCTUnwrap(text.textStorage)
        XCTAssertEqual(text.string, warning.displayMessage + "\n" + error.displayMessage + "\n")
        let warningColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let continuation = (text.string as NSString).range(of: "second line").location
        XCTAssertEqual(storage.attribute(.foregroundColor, at: continuation, effectiveRange: nil) as? NSColor, warningColor)
        let errorPosition = (text.string as NSString).range(of: "[Error]").location
        let errorColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: errorPosition, effectiveRange: nil) as? NSColor)
        XCTAssertNotEqual(warningColor, errorColor)
        XCTAssertFalse(document.scrollView.hasHorizontalScroller); XCTAssertFalse(document.scrollView.hasVerticalScroller)
    }
    @MainActor func testLightAndDarkLogSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_LOG_RENDER_DIRECTORY"] else {
            throw XCTSkip("Set V2RAYM_LOG_RENDER_DIRECTORY for offline light/dark log snapshots")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let font = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/V2rayM/Resources/Fonts/LXGWWenKaiMono-Medium.ttf")
        CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        let document = NativeLogDocument()
        let view = document.scrollView
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 300)
        let fixtures = [entry("core", "core.started", sequence: 1),
            entry("core", "2026/10/24 12:00:01 [Info] 代理连接已建立", sequence: 2),
            entry("core", "2026/10/24 12:00:02 [Warning] 网络暂时不可用，等待重试", sequence: 3),
            entry("core", "2026/10/24 12:00:03 [Error] 无法连接服务器\n    dial tcp: connection refused", sequence: 4),
            entry("core", "2026/10/24 12:00:04 [Debug] outbound: resolving example.com", sequence: 5),
            entry("core", "from tcp:127.0.0.1:52136 accepted tcp:example.com:443 [socks >> proxy]", sequence: 6),
            entry("core", "core.stopped", sequence: 7)]
        document.update(fixtures)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("logs-\(name).png"))
        }
    }
}
