import AppKit
import SwiftUI
import XCTest
@testable import V2rayM
@testable import V2rayMKit

@MainActor final class LogConsoleRenderingTests: XCTestCase {
    private func row(_ n: Int) -> LogEntry {
        LogEntry(timestamp: "fixture", source: "core", message: "record[\(n)] 宽日志 synthetic.example " +
            String(repeating: "long-line-", count: 24) + (n.isMultiple(of: 11) ? "\ncontinued: 续行" : ""), sequence: Int64(n))
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func capture(_ window: NSWindow, to file: URL) throws {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
    }

    func testSavedLogsStayVisibleWhileRuntimeReconnects() async throws {
        AppFont.register()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(dataDirectory: root)
        var log = RollingLogBuffer()
        _ = log.append([row(11), row(12)])
        model.logState.publish(log)
        model.ready = true
        let host = NSHostingView(rootView: ContentView(initialPage: .logs).environmentObject(model)
            .frame(width: 860, height: 600).environment(\.colorScheme, .dark).environment(\.dashboardVisibilityOverride, true))
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 860, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func waitForUpdate() async throws {
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
        }
        try await waitForUpdate()
        let original = try XCTUnwrap(textView(in: host))
        XCTAssertTrue(original.string.contains("record[11]"))
        model.ready = false
        model.connecting = true
        try await waitForUpdate()
        XCTAssertTrue(textView(in: host) === original, "Runtime reconnect hid the log document")
        model.connecting = false
        try await waitForUpdate()
        XCTAssertTrue(textView(in: host) === original, "Disconnected runtime hid saved log records")
        if let path = ProcessInfo.processInfo.environment["V2RAYM_LOG_CHURN_RENDER_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try capture(window, to: directory.appendingPathComponent("disconnected-history.png"))
        }
        model.ready = true
        try await waitForUpdate()
        XCTAssertTrue(textView(in: host) === original)
    }

    func testLiveEvictionAndRemountKeepTextInTheVisibleWindow() async throws {
        AppFont.register()
        let model = AppModel(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.ready = true
        let original = (0..<10_000).map(row)
        var log = RollingLogBuffer()
        _ = log.append(original)
        model.logState.publish(log)
        func content(_ showLogs: Bool) -> AnyView {
            AnyView(RealityWindow {
                if showLogs { ObservedLogConsole(state: model.logState).padding(3).realityField().padding(8) }
                else { Text("主页") }
            }.font(AppFont.body).frame(width: 860, height: 568)
                .environment(\.colorScheme, .dark).environment(\.dashboardVisibilityOverride, true))
        }
        let host = NSHostingView(rootView: content(true))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 860, height: 568),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let requested = ProcessInfo.processInfo.environment["V2RAYM_LOG_CHURN_RENDER_DIRECTORY"]
        let output = requested.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { if requested == nil { try? FileManager.default.removeItem(at: output) } }

        func rendered(_ label: String) async throws {
            try await Task.sleep(for: .milliseconds(60))
            let file = output.appendingPathComponent(label + ".png")
            try capture(window, to: file)
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file))?.cgImage)
            // Count text across the upper/middle/lower thirds, excluding edges
            // of the scroll well. This detects a grey area even if AX still has text.
            let w = 400, h = 230
            var gray = [UInt8](repeating: 0, count: w * h)
            try gray.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            for band in [10..<70, 85..<145, 160..<210] {
                let ink = band.filter { y in gray[(y*w+15)..<(y*w+270)].filter { $0 > 105 }.count >= 8 }.count
                XCTAssertGreaterThan(ink, 8, "\(label) has no text in band \(band)")
            }
        }

        try await rendered("mounted-tail")
        let text = try XCTUnwrap(textView(in: host))
        let clip = try XCTUnwrap(text.enclosingScrollView?.contentView)
        let line = try XCTUnwrap(text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle).minimumLineHeight
        clip.scroll(to: CGPoint(x: 95, y: 5000 * line))
        try await rendered("scrolled-history")
        for batch in 0..<12 {
            let n = 10000 + batch * 60
            _ = log.append((n..<n+60).map(row))
            model.logState.publish(log)
            try await Task.sleep(for: .milliseconds(16))
        }
        try await rendered("evicted-history")
        let oldOrigin = clip.bounds.origin
        host.rootView = content(false)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertNil(textView(in: host))
        host.rootView = content(true)
        try await rendered("returned-history")
        let returned = try XCTUnwrap(textView(in: host))
        XCTAssertTrue(returned === text)
        let restored = try XCTUnwrap(returned.enclosingScrollView?.contentView)
        XCTAssertEqual(restored.bounds.minY, oldOrigin.y, accuracy: 1)
        XCTAssertEqual(restored.bounds.minX, oldOrigin.x, accuracy: 1)
    }
}
