import AppKit
import SwiftUI
import XCTest
@testable import V2rayM
@testable import V2rayMKit

@MainActor final class InitialDashboardPresentationTests: XCTestCase {
    private let size = CGSize(width: 200, height: 100)
    private let gauge = CGRect(x: 20, y: 10, width: 80, height: 80)

    private func frame(scale: Int, drawsRing: Bool) throws -> NSImage {
        let drawing = try XCTUnwrap(CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        drawing.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawing.setFillColor(gray: 0.07, alpha: 1)
        drawing.fill(CGRect(origin: .zero, size: size))
        if drawsRing {
            drawing.setStrokeColor(gray: 0.3, alpha: 1)
            drawing.setLineWidth(3)
            drawing.strokeEllipse(in: gauge.insetBy(dx: 2, dy: 2))
        }
        return NSImage(cgImage: try XCTUnwrap(drawing.makeImage()), size: size)
    }

    func testNilAndTitleOnlyFramesAreRetriedAtBothBackingScales() async throws {
        for scale in [1, 2] {
            let gate = InitialDashboardPresentation(), window = NSWindow()
            let empty = try frame(scale: scale, drawsRing: false), ready = try frame(scale: scale, drawsRing: true)
            var remaining: [NSImage?] = [nil, empty, ready]
            let done = expectation(description: "first composed frame")
            gate.attach(to: window) { image in XCTAssertTrue(image === ready); done.fulfill() }
            XCTAssertEqual(window.alphaValue, 0)
            gate.render(gauge: gauge, stageSize: size) { publish in
                XCTAssertEqual(window.alphaValue, 0)
                guard !remaining.isEmpty else { XCTFail("Readback continued after first complete frame"); return }
                publish(remaining.removeFirst())
            }
            await fulfillment(of: [done], timeout: 1)
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertEqual(window.alphaValue, 1)
        }
    }

    func testTimeoutAndDetachmentReleaseWindowAndIgnoreLateGPUCompletion() async throws {
        let gate = InitialDashboardPresentation(), window = NSWindow()
        window.alphaValue = 0.8
        var count = 0
        var late: ((NSImage?) -> Void)?
        let done = expectation(description: "GPU times out")
        gate.attach(to: window, timeout: 0.15) { image in XCTAssertNil(image); count += 1; done.fulfill() }
        gate.render(gauge: gauge, stageSize: size) { late = $0 }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(window.alphaValue, 0.8, accuracy: 0.01)
        try XCTUnwrap(late)(frame(scale: 1, drawsRing: true))
        XCTAssertEqual(count, 1)
        gate.attach(to: window) { _ in XCTFail("Detached window was revealed by a stale callback") }
        late?(nil)
        XCTAssertEqual(window.alphaValue, 0)
        gate.detach()
        XCTAssertEqual(window.alphaValue, 0.8, accuracy: 0.01)
    }

    func testPageHostIsolatesSurfaceParentsAndKeepsTheCardFaceHierarchy() throws {
        let foreign = UUID(), pageID = UUID(), cardID = UUID(), childID = UUID(), ringID = UUID()
        let navigation = PageCubeNavigation()
        let content = RealityWindow {
            PageTurnHost(page: .home, navigation: navigation) {
                ZStack {
                    RealitySurface(style: .init(shape: .panel(1)), id: pageID)
                    RealitySurface(style: .init(shape: .panel(1)), id: cardID, attachesToSceneRoot: true)
                    RealitySurface(style: .init(shape: .group), id: childID)
                        .environment(\.realityParentSurface, cardID)
                    RealitySurface(style: .init(shape: .ringTrack), id: ringID, attachesToSceneRoot: true)
                        .environment(\.realityParentSurface, foreign)
                }
            }
            .environment(\.realityParentSurface, foreign)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let scene = try XCTUnwrap(navigation.view?.scene)
        scene.stage?.synchronize()
        let children = scene.root.children.map(\.name)
        XCTAssertTrue(children.contains("surface-" + pageID.uuidString))
        XCTAssertTrue(children.contains("surface-" + ringID.uuidString))
        let card = try XCTUnwrap(scene.root.findEntity(named: "surface-" + cardID.uuidString))
        XCTAssertTrue(card.parent === scene.root)
        XCTAssertTrue(card.children.contains { $0.name == "surface-" + childID.uuidString })
    }

    func testRevealedWindowKeepsRendererAfterAnIncompleteFreeze() async throws {
        let scene = RealityWindowScene()
        let stage = RealityStageView(owner: scene, preparesDashboard: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = stage
        window.orderBack(nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while window.alphaValue == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(window.alphaValue, 1)
        stage.suspend()
        let feedback = ContinuousClock.now + .seconds(2)
        while stage.suspended && ContinuousClock.now < feedback { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(stage.suspended, "A partial image must not be frozen over the live renderer")
        XCTAssertNotNil(stage.renderer.superview)
    }

    func testFirstVisibleInactiveWindowContainsTheCompositedGauge() async throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_STARTUP_RENDER_DIRECTORY"] else {
            throw XCTSkip("Set V2RAYM_STARTUP_RENDER_DIRECTORY to capture the first WindowServer frame")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(dataDirectory: directory.appendingPathComponent("unused-fixture"))
        model.ready = true
        model.lastStatusRefresh = Date()
        let started = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-360))
        model.status = try JSONDecoder().decode(RuntimeStatus.self, from: JSONSerialization.data(withJSONObject:
            ["coreRunning": true, "runtimeState": "running", "xrayAvailable": true, "coreStartedAt": started,
             "runningProfileId": "fixture", "runningProfileName": "启动测试节点"]))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 860, height: 600),
            styleMask: [.titled, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = ContentView().environmentObject(model).font(AppFont.body)
            .environment(\.presentsInitialDashboard, true)
            .preferredColorScheme(.dark)
            .background(WindowTracker { _ in })
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 860, height: 600))
        window.contentView = host
        window.contentView?.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        XCTAssertEqual(window.alphaValue, 0, "Native text may not appear ahead of the dashboard")
        let deadline = ContinuousClock.now + .seconds(3)
        while window.alphaValue == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(window.alphaValue, 1)
        func stage(_ view: NSView) -> RealityStageView? {
            if let stage = view as? RealityStageView { return stage }
            return view.subviews.lazy.compactMap(stage).first
        }
        let renderer = try XCTUnwrap(stage(host))
        let gauge = try XCTUnwrap(renderer.owner.initialDashboardGauge)
        let imageURL = directory.appendingPathComponent("inactive-first.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), imageURL.path]
        try capture.run(); capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
        let image = try XCTUnwrap(NSImage(contentsOf: imageURL))
        XCTAssertTrue(InitialDashboardPresentation.containsGauge(image, frame: gauge, stageSize: renderer.bounds.size))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host)
        let clock = try XCTUnwrap(views.compactMap { $0 as? NumericLayerView }.first { view in
            let rect = view.convert(view.bounds, to: renderer)
            return gauge.contains(CGPoint(x: rect.midX, y: rect.midY))
        })
        let shield = try XCTUnwrap(views.compactMap { $0 as? RealitySurfaceAnchor }.first {
            $0.style.shape == .glyph(.shieldActive)
        })
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        for region in [clock as NSView, shield as NSView] {
            let rect = region.convert(region.bounds, to: renderer)
            let pixels = rect.applying(CGAffineTransform(scaleX: CGFloat(bitmap.width) / renderer.bounds.width,
                                                        y: CGFloat(bitmap.height) / renderer.bounds.height)).integral
            let crop = try XCTUnwrap(bitmap.cropping(to: pixels))
            var values = [UInt8](repeating: 0, count: crop.width * crop.height)
            values.withUnsafeMutableBytes { bytes in
                let ctx = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
                ctx?.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            XCTAssertGreaterThan(Int(values.max() ?? 0) - Int(values.min() ?? 0), 32,
                                 "The clock and active shield must already be visible on the first frame")
        }
        XCTAssertFalse(window.isKeyWindow)
        // Exercise AppKit's suspension/resume callbacks without moving the
        // user's Dock or requiring a foreground host application.
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: window)
        XCTAssertTrue(renderer.suspended)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        renderer.resume()
        XCTAssertFalse(renderer.suspended)
        XCTAssertNotNil(renderer.renderer.superview)
        XCTAssertEqual(window.alphaValue, 1, "Restoring a prepared window must not re-enter startup")
    }
}
