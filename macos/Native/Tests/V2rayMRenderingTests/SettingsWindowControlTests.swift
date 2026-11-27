import AppKit
import SwiftUI
import XCTest
@testable import V2rayM
@testable import V2rayMKit

@MainActor final class SettingsWindowControlTests: XCTestCase {
    private func window<V: View>(_ content: V, height: CGFloat) async throws -> NSWindow {
        AppFont.register()
        let host = NSHostingView(rootView: RealityWindow {
            content.font(AppFont.body).foregroundStyle(DashboardTheme.text)
                .buttonStyle(HoverButtonStyle())
                .frame(width: 860, height: height)
        }.environment(\.colorScheme, .dark).environment(\.dashboardVisibilityOverride, true))
        let window = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 860, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(300))
        return window
    }

    private func anchors(_ view: NSView) -> [RealitySurfaceAnchor] {
        ([view as? RealitySurfaceAnchor].compactMap { $0 }) + view.subviews.flatMap(anchors)
    }

    func testOverviewCardsFillViewportAndShortViewportsRetainAllRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(dataDirectory: root)
        model.ready = true
        for height: CGFloat in [568, 420] {
            let window = try await window(SettingsPage(navigationLocked: .constant(false)).environmentObject(model), height: height)
            defer { window.close() }
            let host = try XCTUnwrap(window.contentView)
            let cards = anchors(host).filter { $0.style.shape == .cardPanel(10) }
            XCTAssertEqual(cards.count, 5)
            let rects = cards.map { $0.convert($0.bounds, to: host) }
            let bounds = rects.reduce(CGRect.null) { $0.union($1) }
            XCTAssertEqual(bounds.minX, PageLayout.gap, accuracy: 1)
            XCTAssertEqual(bounds.maxX, host.bounds.maxX - PageLayout.gap, accuracy: 1)
            let top = host.isFlipped ? bounds.minY : host.bounds.maxY - bounds.maxY
            XCTAssertEqual(top, PageLayout.gap, accuracy: 1)
            let scroll = try XCTUnwrap(cards.first?.enclosingScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            if height == 568 {
                XCTAssertEqual(bounds.height, height - 2 * PageLayout.gap, accuracy: 1)
                XCTAssertLessThanOrEqual(document.frame.height, scroll.contentSize.height + 1)
            } else {
                XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
                XCTAssertGreaterThan(bounds.height, scroll.contentSize.height)
            }
        }
    }

    func testBusinessButtonsShowTextAndRespondToEligibleClicks() async throws {
        var loginClicks = 0, updates = 0
        let progress = ModuleUpdateProgress(phase: "completed", isComplete: true, success: true, detail: "测试详情")
        for completed in [false, true] {
            let fixture = VStack(spacing: 12) {
                LoginItemStatusRow(registered: .constant(true), requiresApproval: false, bundled: true,
                                   updating: false, openSettings: { loginClicks += 1 })
                ModuleUpdateRow(progress: completed ? progress : nil, queued: false,
                                disabled: false, update: { updates += 1 })
            }.padding(16)
            let window = try await window(fixture, height: 120)
            defer { window.close() }
            let host = try XCTUnwrap(window.contentView)
            let buttons = anchors(host).filter { $0.style.shape == .panel(5) && $0.style.level == 75 }
                .sorted { $0.bounds.width < $1.bounds.width }
            XCTAssertEqual(buttons.count, 3)
            guard buttons.count == 3 else { return }
            let detail = buttons[0], update = buttons[1], login = buttons[2]
            XCTAssertEqual(detail.style.enabled, completed)
            XCTAssertTrue(update.style.enabled)
            XCTAssertTrue(login.style.enabled)
            let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: captureURL) }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), captureURL.path]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: captureURL))?.cgImage)
            // Sample the interior, excluding the bevel. A blank 3D plate cannot
            // pass merely because the SwiftUI accessibility tree has a label.
            for button in buttons {
                let frame = button.convert(button.bounds, to: host).insetBy(dx: 4, dy: 3)
                let scale = CGFloat(image.width) / host.bounds.width
                let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
                let region = CGRect(x: frame.minX * scale, y: top * scale, width: frame.width * scale, height: frame.height * scale)
                let crop = try XCTUnwrap(image.cropping(to: region))
                var pixels = [UInt8](repeating: 0, count: crop.width * crop.height)
                try pixels.withUnsafeMutableBytes { bytes in
                    let ctx = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                        bitsPerComponent: 8, bytesPerRow: crop.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
                    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                }
                let sorted = pixels.sorted()
                XCTAssertGreaterThan(Int(sorted[sorted.count * 95 / 100]) - Int(sorted[sorted.count / 10]), 35)
            }

            func click(_ anchor: NSView) throws {
                let point = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
            }
            try click(login)
            try click(update)
            XCTAssertEqual(loginClicks, completed ? 2 : 1)
            XCTAssertEqual(updates, completed ? 2 : 1)
            let existingWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            try click(detail)
            try await Task.sleep(for: .milliseconds(120))
            let opened = NSApp.windows.filter { $0.isVisible && !existingWindows.contains($0.windowNumber) }
            XCTAssertEqual(!opened.isEmpty, completed)
        }
    }
}
