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
    func testLateAttachedNestedScrollAncestorsMoveSurfacesTogether() throws {
        let stage = RealityStageView(owner: RealityWindowScene())
        // Both clips are attached after the anchor enters its immediate parent,
        // as SwiftUI does when assembling a settings card and its route scroller.
        let outer = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let inner = NSScrollView(frame: CGRect(x: 0, y: 300, width: 400, height: 100))
        let nested = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 100))
        let anchor = RealitySurfaceAnchor()
        anchor.frame = CGRect(x: 120, y: 20, width: 100, height: 40)
        nested.addSubview(anchor)
        inner.documentView = nested; document.addSubview(inner); outer.documentView = document
        let container = NSView(frame: outer.frame)
        // Use one scene for the stage and anchor.
        stage.frame = container.bounds; container.addSubview(stage); container.addSubview(outer)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = container
        defer { stage.stop(); window.close() }
        outer.contentView.scroll(to: CGPoint(x: 0, y: 250))
        stage.owner.resize(container.bounds.size)
        anchor.configure(scene: stage.owner, style: .init())
        func assertAligned(file: StaticString = #filePath, line: UInt = #line) throws {
            let entity = try XCTUnwrap(stage.owner.root.findEntity(named: "surface-" + anchor.surfaceID.uuidString), file: file, line: line)
            let rect = anchor.convert(anchor.bounds, to: stage).intersection(anchor.convert(anchor.visibleRect, to: stage)).intersection(stage.bounds)
            XCTAssertFalse(rect.isEmpty, file: file, line: line)
            let expected = RealityWindowScene.position(rect, viewport: stage.bounds.size, level: anchor.style.level)
            XCTAssertEqual(entity.position.x, expected.x, accuracy: 0.00001, file: file, line: line)
            XCTAssertEqual(entity.position.y, expected.y, accuracy: 0.00001, file: file, line: line)
        }
        try assertAligned()
        outer.contentView.scroll(to: CGPoint(x: 0, y: 280))
        try assertAligned()
        inner.contentView.scroll(to: CGPoint(x: 30, y: 0))
        try assertAligned()
        outer.contentView.scroll(to: CGPoint(x: 0, y: 260))
        try assertAligned()
        anchor.detach()
        XCTAssertEqual(stage.owner.entityCount, 0)
    }
    func testReclickAndSwitchThroughWindowHitTargets() async throws {
        let model = AppModel(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.ready = true
        let host = NSHostingView(rootView: ContentView().environmentObject(model).environment(\.dashboardVisibilityOverride, true).background(WindowTracker { _ in }))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 860, height: 600),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        try await Task.sleep(for: .milliseconds(500))
        for label in ["节点", "节点", "日志", "设置", "主页"] {
            let button = try XCTUnwrap(all(host).compactMap { $0 as? NSButton }.first { $0.toolTip == label })
            let screenPoint = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let target = host.hitTest(host.superview!.convert(screenPoint, from: nil))
            XCTAssertTrue(target === button, "\(label) hit \(String(describing: target))")
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: screenPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            let stage = try XCTUnwrap(all(host).compactMap { $0 as? RealityStageView }.first)
            window.sendEvent(try event(.leftMouseDown))
            window.sendEvent(try event(.leftMouseUp))
            try await Task.sleep(for: .milliseconds(90))
            XCTAssertEqual(button.accessibilityValue() as? String, "已选中")
            XCTAssertGreaterThan(stage.owner.activeNavigationFlips, 0, label)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(stage.owner.activeNavigationFlips, 0)
        }
    }

    func testRowArrivingBeforeCardIsOnlyVisibleInsideFrontFace() throws {
        let scene = RealityWindowScene(), parent = UUID(), row = UUID()
        scene.resize(CGSize(width: 860, height: 600))
        let local = CGRect(x: -100,y: -9,width: 200,height: 18)
        scene.update(row, frame: local, visible: local, style: .init(parentID: parent, rowOffset: 0))
        XCTAssertNil(scene.root.findEntity(named: "surface-" + row.uuidString))
        let frame = CGRect(x: 560,y: 380,width: 270,height: 190)
        for angle in [180.0, 300.0, 360.0] {
            scene.update(parent, frame: frame, visible: frame, style: .init(shape: .dashboard(.card), angle: angle))
            let card = try XCTUnwrap(scene.root.findEntity(named: "surface-" + parent.uuidString))
            let child = try XCTUnwrap(card.findEntity(named: "surface-" + row.uuidString))
            XCTAssertTrue(child.parent === card)
            XCTAssertEqual(child.isEnabled, angle != 180)
            XCTAssertEqual(child.position.x, 0)
            XCTAssertEqual(child.position.y, 0)
        }
    }

    func testToolbarMotionSurvivesALateFrameAndSwitchReversal() throws {
        let stage = RealityStageView(owner: RealityWindowScene())
        let scene = stage.owner
        let rect = CGRect(x: 10, y: 5, width: 30, height: 18)
        scene.resize(CGSize(width: 860, height: 600))
        let toggle = UUID(), icon = UUID()
        func setSwitch(_ on: Bool, reduced: Bool = false) {
            scene.update(toggle, frame: rect, visible: rect, style: .init(allowsFlip: !reduced, switchOn: on))
        }
        setSwitch(false)
        let track = try XCTUnwrap(scene.root.findEntity(named: "surface-" + toggle.uuidString))
        let thumb = try XCTUnwrap(track.findEntity(named: "switch-thumb"))
        setSwitch(true)
        scene.update(icon, frame: rect, visible: rect, style: .init(shape: .symbol(.home)))
        scene.update(icon, frame: rect, visible: rect, style: .init(shape: .symbol(.home), flipToken: 1))
        scene.advanceMotion(by: 0.6)
        XCTAssertEqual(scene.activeNavigationFlips, 1, "One slow frame must not finish the turn")
        let halfway = thumb.position.x
        XCTAssertGreaterThan(halfway, -0.006)
        XCTAssertLessThan(halfway, 0)
        setSwitch(false)
        XCTAssertEqual(thumb.position.x, halfway, accuracy: 0.000001)
        scene.advanceMotion(by: 1.0/60.0)
        XCTAssertLessThan(thumb.position.x, halfway)
        for _ in 0..<30 { scene.advanceMotion(by: 1.0/60.0) }
        XCTAssertEqual(thumb.position.x, -0.006, accuracy: 0.000001)
        XCTAssertEqual(scene.activeNavigationFlips, 0)
        setSwitch(true, reduced: true)
        XCTAssertEqual(thumb.position.x, 0.006, accuracy: 0.000001)
    }

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
                    level: 70, selected: i == 0, enabled: enabled, angle: -16, tilt: 12,
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
    func testFullyClippedSurfacesDoNotLeaveOrphanEntities() {
        let scene = RealityWindowScene(), id = UUID()
        scene.resize(CGSize(width: 400, height: 200))
        let viewport = CGRect(x: 0, y: 26, width: 400, height: 174)
        for _ in 0..<20 {
            scene.update(id, frame: CGRect(x: 30, y: -50, width: 60, height: 20), visible: viewport, style: .init())
        }
        XCTAssertEqual(scene.entityCount, 0)
        XCTAssertNil(scene.root.findEntity(named: "surface-" + id.uuidString))
        scene.update(id, frame: CGRect(x: 30, y: 40, width: 60, height: 20), visible: viewport, style: .init())
        XCTAssertEqual(scene.root.children.filter { $0.name == "surface-" + id.uuidString }.count, 1)
        scene.update(id, frame: CGRect(x: 30, y: -50, width: 60, height: 20), visible: viewport, style: .init())
        XCTAssertFalse(scene.root.findEntity(named: "surface-" + id.uuidString)?.isEnabled ?? true)
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
            if page == .settings {
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
                    .first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 20 })
                let document = try XCTUnwrap(scroll.documentView)
                let maxY = document.bounds.height - scroll.contentView.bounds.height
                let wheelAnchor = try XCTUnwrap(descendants(document).compactMap { $0 as? SettingsWheelScroll.Anchor }.first { $0.enclosingScrollView === scroll })
                let nativeWheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                    wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
                let wheelEvent = try XCTUnwrap(NSEvent(cgEvent: nativeWheel))
                let location = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                let origin = scroll.contentView.bounds.minY
                XCTAssertTrue(wheelAnchor.consume(wheelEvent, at: location))
                XCTAssertEqual(scroll.contentView.bounds.minY, origin)
                try await Task.sleep(for: .milliseconds(210))
                XCTAssertEqual(scroll.contentView.bounds.minY, origin + 3 * scroll.verticalLineScroll, accuracy: 1)
                let precise = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
                precise.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                XCTAssertFalse(wheelAnchor.consume(try XCTUnwrap(NSEvent(cgEvent: precise)), at: location))
                for (index, offset) in [min(90, maxY), maxY, 0].enumerated() {
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(100))
                    for anchor in descendants(document).compactMap({ $0 as? RealitySurfaceAnchor }) {
                        var rect = anchor.convert(anchor.bounds, to: renderer)
                            .intersection(anchor.convert(anchor.visibleRect, to: renderer)).intersection(renderer.bounds)
                        if let viewportID = anchor.style.viewportID {
                            let viewport = try XCTUnwrap(descendants(host).compactMap { $0 as? RealityViewportAnchor }.first { $0.id == viewportID })
                            let visible = viewport.convert(viewport.bounds, to: renderer).intersection(renderer.bounds)
                            XCTAssertGreaterThanOrEqual(visible.minY, TitleBarGeometry.topMargin + TitleBarGeometry.height, "Settings must stay below the title bar")
                            rect = rect.intersection(visible)
                        }
                        let existing = renderer.owner.root.findEntity(named: "surface-" + anchor.surfaceID.uuidString)
                        if rect.isEmpty || !anchor.style.visible {
                            XCTAssertFalse(existing?.isEnabled ?? false, "Offscreen settings must not paint over navigation")
                            continue
                        }
                        guard anchor.style.parentID == nil else { continue }
                        let entity = try XCTUnwrap(existing)
                        let expected = RealityWindowScene.position(rect, viewport: renderer.bounds.size, level: anchor.style.level)
                        XCTAssertEqual(entity.position.x, expected.x, accuracy: 0.00001)
                        XCTAssertEqual(entity.position.y, expected.y, accuracy: 0.00001, "Card background must follow native text at scroll offset \(offset)")
                    }
                    let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-l", String(window.windowNumber), folder.appendingPathComponent("settings-scroll-\(index).png").path]
                    try capture.run(); capture.waitUntilExit(); XCTAssertEqual(capture.terminationStatus, 0)
                }
            }
            let before = renderer.owner.entityCount
            renderer.suspend(); renderer.resume()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(renderer.suspended)
            XCTAssertNotNil(renderer.renderer.superview, "A stale snapshot must not remove a resumed render view")
            XCTAssertEqual(renderer.owner.entityCount, before)
        }
    }
}
