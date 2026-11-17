import XCTest
import AppKit
import SwiftUI
import RealityKit
@testable import V2rayM
@testable import V2rayMKit

@MainActor private final class RealityInteractionFixture: ObservableObject {
    @Published var clicks = 0
    @Published var enabled = true
    @Published var text = ""
    @Published var toggle = false
}
private struct RealityInteractionView: View {
    @ObservedObject var state: RealityInteractionFixture
    var body: some View {
        RealityWindow {
            ZStack(alignment: .topLeading) {
                Button("测试操作") { state.clicks += 1 }
                    .disabled(!state.enabled).position(x: 60, y: 30)
                Toggle("测试开关", isOn: $state.toggle).toggleStyle(RealityToggleStyle())
                    .position(x: 240, y: 30)
                TextField("输入", text: $state.text).textFieldStyle(RealityTextFieldStyle())
                    .frame(width: 180).position(x: 100, y: 80)
            }.frame(width: 400, height: 120)
        }.buttonStyle(HoverButtonStyle()).font(AppFont.body).environment(\.colorScheme, .dark)
    }
}

@MainActor final class RealityWindowTests: XCTestCase {
    func testNavigationAssetFlipsCoalesceAndRespectCancellation() async throws {
        let stage = RealityStageView(owner: RealityWindowScene())
        let owner = stage.owner
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = stage
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { stage.stop(); window.close() }
        stage.layoutSubtreeIfNeeded(); owner.resize(CGSize(width: 800, height: 220))
        let ids = RealityNavigationSymbol.allCases.map { _ in UUID() }
        func update(token: Int, enabled: Bool = true, motion: Bool = true) {
            for (i,symbol) in RealityNavigationSymbol.allCases.enumerated() {
                let rect = CGRect(x: 30+i*200, y: 40, width: 140, height: 140)
                owner.update(ids[i], frame: rect, visible: rect, style: .init(shape: .symbol(symbol),
                    level: 70, highlighted: i == 0, enabled: enabled, angle: -27, tilt: 18,
                    flipToken: token, allowsFlip: motion))
            }
        }
        update(token: 0)
        try await Task.sleep(for: .milliseconds(300))
        if let output = ProcessInfo.processInfo.environment["V2RAYM_REALITY_RENDER_DIRECTORY"] {
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), URL(fileURLWithPath: output).appendingPathComponent("navigation-assets.png").path]
            try capture.run(); capture.waitUntilExit(); XCTAssertEqual(capture.terminationStatus, 0)
        }
        update(token: 1)
        XCTAssertEqual(owner.activeNavigationFlips, 4)
        update(token: 2)
        XCTAssertEqual(owner.activeNavigationFlips, 4, "Hover and selection must share one active turn")
        update(token: 3, enabled: false)
        XCTAssertEqual(owner.activeNavigationFlips, 0)
        update(token: 4, motion: false)
        XCTAssertEqual(owner.activeNavigationFlips, 0)
        update(token: 5)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(owner.activeNavigationFlips, 0)
        update(token: 6); stage.suspend()
        XCTAssertEqual(owner.activeNavigationFlips, 0)
    }
    func testNativeActionsAndEditingThroughRealityScene() async throws {
        let state = RealityInteractionFixture()
        let host = NSHostingView(rootView: RealityInteractionView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        func click(_ point: CGPoint) throws {
            let location = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        try click(CGPoint(x: 60, y: 30))
        XCTAssertEqual(state.clicks, 1)
        state.enabled = false
        try await Task.sleep(for: .milliseconds(50))
        try click(CGPoint(x: 60, y: 30))
        XCTAssertEqual(state.clicks, 1, "Disabled controls must remain inert")
        try click(CGPoint(x: 240, y: 30))
        XCTAssertTrue(state.toggle)
        try click(CGPoint(x: 90, y: 80))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("中文输入", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.text, "中文输入")
    }

    func testNavigationSymbolsAreBoundedSolidGeometryAndPlotClips() throws {
        for symbol in RealityNavigationSymbol.allCases {
            let asset = try RealityNavigationAssets.build(symbol)
            let bounds = asset.visualBounds(relativeTo: nil)
            XCTAssertGreaterThan(bounds.extents.z, 0.1, "Every icon must be a volumetric model")
            XCTAssertGreaterThan(bounds.extents.x, 0.5)
            XCTAssertLessThan(bounds.extents.y, 2.5)
            let loaded = try RealityNavigationAssets.load(symbol)
            XCTAssertGreaterThan(loaded.visualBounds(relativeTo: nil).extents.z, 0.1)

        }
        let clipped = try XCTUnwrap(RealityPlotGeometry.clip(CGPoint(x: -20, y: 10), CGPoint(x: 120, y: 10), size: CGSize(width: 100, height: 20)))
        XCTAssertEqual(clipped.0.x, 0, accuracy: 0.0001); XCTAssertEqual(clipped.1.x, 100, accuracy: 0.0001)
        XCTAssertNil(RealityPlotGeometry.clip(CGPoint(x: -20, y: 30), CGPoint(x: 120, y: 30), size: CGSize(width: 100, height: 20)))
    }
    func testPointCoordinatesMatchNativeHitRegions() {
        let viewport = CGSize(width: 860, height: 600)
        let center = RealityWindowScene.position(CGRect(x: 420, y: 290, width: 20, height: 20), viewport: viewport, level: 20)
        XCTAssertEqual(center, SIMD3<Float>(0, 0, 0.02))
        let top = RealityWindowScene.position(CGRect(x: 0, y: 0, width: 20, height: 20), viewport: viewport, level: 0)
        XCTAssertEqual(top.x, -0.42, accuracy: 0.00001)
        XCTAssertEqual(top.y, 0.29, accuracy: 0.00001)
    }

    func testMeshesReuseGeometryAcrossHoverAndRotationAndRetire() throws {
        let scene = RealityWindowScene()
        scene.resize(CGSize(width: 860, height: 600))
        let id = UUID(), rect = CGRect(x: 12, y: 40, width: 260, height: 150)
        var style = RealitySurfaceStyle()
        scene.update(id, frame: rect, visible: rect, style: style)
        XCTAssertEqual(scene.meshBuilds, 1)
        for i in 0..<180 {
            style.angle = Double(i); style.highlighted = i % 2 == 0
            scene.update(id, frame: rect, visible: rect, style: style)
        }
        XCTAssertEqual(scene.meshBuilds, 1, "Animation must transform an existing entity, not rebuild a mesh")
        XCTAssertEqual(scene.entityCount, 1)
        scene.remove(id)
        XCTAssertEqual(scene.entityCount, 0)
    }

    func testShapesStayWithinTheirNativeLayoutBounds() throws {
        for shape in [RealityShape.panel(14), .panel(100), .disc] {
            let polygon = RealityGeometry.outline(shape: shape, size: CGSize(width: 50, height: 20))
            XCTAssertFalse(polygon.isEmpty)
            for point in polygon {
                XCTAssertLessThanOrEqual(abs(point.x), 0.02501)
                XCTAssertLessThanOrEqual(abs(point.y), 0.01001)
                XCTAssertTrue(point.x.isFinite && point.y.isFinite)
            }
        }
        for fraction in [Double.nan, -Double.infinity, -1, 0, 0.5, 1, 2] {
            _ = try RealityGeometry.mesh(shape: .ring(fraction), size: CGSize(width: 100, height: 100), depth: 5)
        }
    }

    func testWholeWindowOfflineRenderingAndLifecycle() async throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_REALITY_RENDER_DIRECTORY"] else {
            throw XCTSkip("Set V2RAYM_REALITY_RENDER_DIRECTORY for GPU window acceptance")
        }
        AppFont.register()
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("v2raym-reality-fixture-" + UUID().uuidString)
        let model = AppModel(dataDirectory: data)
        defer { try? FileManager.default.removeItem(at: data) }
        model.ready = true
        model.profiles = try JSONDecoder().decode([Profile].self, from: Data("""
        [{"indexId":"fixture","remarks":"RealityKit · 测试节点","protocol":"vless","address":"example.invalid","port":443,
        "network":"xhttp","streamSecurity":"tls","coreType":"Xray","delay":42,"isCurrent":true,"totalUp":1024,"totalDown":2048,"canTest":true}]
        """.utf8))
        let now = Date(), formatter = ISO8601DateFormatter()
        model.systemProxyEnabled = true
        model.lastStatusRefresh = now
        for i in 0...60 {
            let date = now.addingTimeInterval(Double(i-60)*5)
            let payload: [String: Any] = ["coreRunning": true, "xrayAvailable": true, "runtimeState": "running",
                "runningProfileId": "fixture", "coreStartedAt": formatter.string(from: now.addingTimeInterval(-360)),
                "trafficEnabled": true, "statisticsEnabled": true, "installedXrayVersion": "26.11.9",
                "traffic": ["proxyUp": Double(20+i%13)*60, "proxyDown": Double(800+i%19*100)*60,
                    "directUp": Double(100+i%17*20)*60, "directDown": Double(400+i%23*50)*60,
                    "sampleSeconds": 60, "sampledAt": formatter.string(from: date)]]
            let state = try JSONDecoder().decode(RuntimeStatus.self, from: JSONSerialization.data(withJSONObject: payload))
            model.telemetry.record(state, now: date); model.status = state
        }
        let entries = (1...7).map { i in LogEntry(timestamp: formatter.string(from: now), source: "core",
            message: "from tcp:127.0.0.1:1234 accepted tcp:192.0.2.\(i):443 [socks >> \(i > 4 ? "direct" : "proxy")]", sequence: Int64(i)) }
        model.dashboard.update(state: try XCTUnwrap(model.status), node: nil, entries: entries)
        model.logState.entries = entries
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 860, height: 600), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        for page in Page.allCases {
            let host = NSHostingView(rootView: ContentView(initialPage: page).environmentObject(model)
                .font(AppFont.body).buttonStyle(HoverButtonStyle()).environment(\.colorScheme, .dark)
                .background(WindowTracker { _ in }))
            window.contentView = host
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(1500))
            host.layoutSubtreeIfNeeded()
            func stage(_ view: NSView) -> RealityStageView? {
                if let found = view as? RealityStageView { return found }
                return view.subviews.compactMap(stage).first
            }
            let renderer = try XCTUnwrap(stage(host))
            let projectedOrigin = try XCTUnwrap(renderer.renderer.project(.zero))
            XCTAssertEqual(projectedOrigin.x, renderer.bounds.midX, accuracy: 0.1)
            XCTAssertEqual(projectedOrigin.y, renderer.bounds.midY, accuracy: 0.1)
            XCTAssertGreaterThan(renderer.owner.entityCount, 5, "Every page must share the window's RealityKit scene")
            XCTAssertNil(renderer.hitTest(.zero), "The renderer must not intercept native controls")
            let path = folder.appendingPathComponent(page.id + ".png")
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), path.path]
            try capture.run(); capture.waitUntilExit(); XCTAssertEqual(capture.terminationStatus, 0)
            let before = renderer.owner.entityCount
            renderer.suspend(); renderer.resume()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(renderer.suspended)
            XCTAssertNotNil(renderer.renderer.superview, "A stale snapshot must not remove a resumed render view")
            XCTAssertEqual(renderer.owner.entityCount, before)
        }
    }
}
