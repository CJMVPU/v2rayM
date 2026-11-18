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
            let anchors = all(host).compactMap { $0 as? RealitySurfaceAnchor }.filter { $0.style.shape.isNavigationSymbol }
            XCTAssertEqual(anchors.count, 4)
            for anchor in anchors {
                let entity = try XCTUnwrap(stage.owner.root.findEntity(named: "surface-" + anchor.surfaceID.uuidString))
                let faceNormal = entity.orientation.act(SIMD3<Float>(0, 0, 1))
                XCTAssertLessThan(simd_distance(faceNormal, [0, 0, 1]), 0.00001)
                XCTAssertLessThan(simd_length(entity.visualBounds(relativeTo: entity).center), 0.00001)
            }
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
                    level: 70, selected: i == 0, enabled: enabled,
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
    func testRetainedSolidsReprojectOnResizeAndIgnoreConversionNoise() throws {
        let scene = RealityWindowScene()
        let frame = CGRect(x: 83, y: 114, width: 149, height: 122)
        scene.resize(CGSize(width: 640, height: 420))
        for body in [DashboardBodyAsset.dial, .card] {
            let id = UUID()
            let style = RealitySurfaceStyle(shape: .dashboard(body))
            scene.update(id, frame: frame, visible: frame, style: style)
            let entity = try XCTUnwrap(scene.root.findEntity(named: "surface-" + id.uuidString))
            let initialBuilds = scene.meshBuilds
            for size in [CGSize(width: 860, height: 600), CGSize(width: 640, height: 420)] {
                scene.resize(size)
                let expected = RealityWindowScene.position(frame, viewport: size, level: style.level)
                XCTAssertEqual(entity.position, expected)
                var noisy = frame
                noisy.size.height += 1e-12
                scene.update(id, frame: noisy, visible: noisy, style: style)
                XCTAssertEqual(scene.meshBuilds, initialBuilds)
                XCTAssertEqual(entity.position, expected)
            }
        }
    }

    func testReplacingAnAnchorKeepsTheNewOwnerOfItsSolid() {
        let scene = RealityWindowScene(), id = UUID()
        let old = RealitySurfaceAnchor(id: id), replacement = RealitySurfaceAnchor(id: id)
        old.configure(scene: scene, style: .init())
        replacement.configure(scene: scene, style: .init())
        old.detach()
        XCTAssertTrue(scene.isRegistered(replacement))
        replacement.detach()
        XCTAssertFalse(scene.isRegistered(replacement))
    }

    func testBackgroundScrollRendersUntilIdleAndHonorsSuspension() async throws {
        let stage = RealityStageView(owner: RealityWindowScene())
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.orderFrontRegardless()
        defer { stage.stop(); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        stage.suspend()
        stage.nativeScrollDidChange()
        XCTAssertTrue(stage.suspended)
        stage.allowBackgroundScroll(true)
        stage.nativeScrollDidChange()
        XCTAssertFalse(stage.suspended)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(stage.suspended)
        stage.nativeScrollDidChange()
        stage.allowBackgroundScroll(false)
        stage.resume()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(stage.suspended)
    }

    func testPlotPanReusesHistoryWhileTailAndOpacityChange() throws {
        let model = RealityPlotModel()
        let size = CGSize(width: 120, height: 50)
        func stroke(_ x: CGFloat) -> RealityPlotStroke {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 10, y: 12))
            path.addLine(to: CGPoint(x: x, y: 20))
            return RealityPlotStroke(path: path, color: NSColor.white.cgColor)
        }
        var history = stroke(70), tail = stroke(90)
        model.update([history, tail], size: size)
        let child = try XCTUnwrap(model.entity.children.first as? ModelEntity)
        let mesh = try XCTUnwrap(child.model?.mesh)
        history.offset = -2
        tail = stroke(96)
        model.update([history, tail], size: size)
        XCTAssertTrue(child.model?.mesh === mesh)
        XCTAssertEqual(child.position.x, -0.002, accuracy: 0.000001)
        history.opacity = 0.5
        model.update([history], size: size)
        XCTAssertTrue(child.model?.mesh === mesh)
        XCTAssertEqual(model.entity.children.count, 1)
        model.update([], size: size)
        XCTAssertTrue(model.entity.children.isEmpty)
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

    func testRealityChoicePreservesDuplicateLabelsAndUsesTheNativePopupAction() async throws {
        let state = RealityInteractionFixture()
        let binding = Binding(get: { state.clicks }, set: { state.clicks = $0 })
        let host = NSHostingView(rootView: RealityWindow {
            RealityChoice(title: "方案", selection: binding, values: [0, 1, 2]) { _ in "相同名称" }
        })
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 180, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(160))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let popup = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(popup.numberOfItems, 3)
        popup.selectItem(at: 2)
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertEqual(state.clicks, 2)
        let anchors = descendants(host).compactMap { $0 as? RealitySurfaceAnchor }
        XCTAssertTrue(anchors.contains { $0.style.shape == .well(5) })
        XCTAssertTrue(anchors.contains { $0.style.shape == .glyph(.down) })
    }

    func testRingRetargetsFromDisplayedLengthAndSettlesWhenMotionStops() throws {
        let scene = RealityWindowScene(), id = UUID()
        let stage = RealityStageView(owner: scene)
        defer { stage.stop() }
        let frame = CGRect(x: 0, y: 0, width: 260, height: 260)
        func set(_ value: Double, animated: Bool = true) {
            scene.update(id, frame: frame, visible: frame, style: .init(shape: .ring(value), animatesRing: animated))
        }
        set(0)
        let entity = try XCTUnwrap(scene.root.findEntity(named: "surface-" + id.uuidString) as? ModelEntity)
        let mesh = try XCTUnwrap(entity.model?.mesh.lowLevelMesh)
        set(1)
        scene.advanceMotion(by: 0.6)
        XCTAssertEqual(mesh.parts.first?.indexCount, mesh.indexCapacity / 2)
        set(0)
        XCTAssertEqual(mesh.parts.first?.indexCount, mesh.indexCapacity / 2)
        scene.advanceMotion(by: 0.6)
        XCTAssertEqual(mesh.parts.first?.indexCount, mesh.indexCapacity / 4)
        set(1, animated: false)
        scene.advanceMotion(by: 1)
        XCTAssertEqual(mesh.parts.first?.indexCount, mesh.indexCapacity)
        XCTAssertEqual(scene.meshBuilds, 1)
    }

    func testPageSlideMovesLiveSurfacesAndKeepsTitleStill() async throws {
        let model = AppModel(dataDirectory: FileManager.default.temporaryDirectory)
        model.ready = true
        let content = ContentView(initialPage: .logs).environmentObject(model)
            .environment(\.dashboardVisibilityOverride, true)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 860, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func button(_ page: Page) throws -> NSButton {
            try XCTUnwrap(views(host).compactMap { $0 as? NSButton }.first { $0.toolTip == page.rawValue })
        }
        func select(_ page: Page) throws {
            let control = try button(page)
            control.sendAction(control.action, to: control.target)
        }
        try await Task.sleep(for: .milliseconds(350))
        let stage = try XCTUnwrap(views(host).compactMap { $0 as? RealityStageView }.first)
        let anchors = views(host).compactMap { $0 as? RealitySurfaceAnchor }
        let title = try XCTUnwrap(anchors.first { $0.style.shape == .dashboard(.titleBar) && $0.style.level == 50 })
        let field = try XCTUnwrap(anchors.first { if case .well = $0.style.shape { return true }; return false })
        let titleX = title.convert(title.bounds, to: stage).midX
        let initialX = field.convert(field.bounds, to: stage).midX
        try select(.settings)
        var intermediate: [CGFloat] = []
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
            guard field.window != nil else { break }
            let frame = field.convert(field.bounds, to: stage)
            if frame.midX < initialX - 1 && frame.maxX > 1 {
                intermediate.append(frame.midX)
                let entity = try XCTUnwrap(stage.owner.root.findEntity(named: "surface-" + field.surfaceID.uuidString))
                let renderedX = CGFloat(entity.position.x) * 1000 + stage.bounds.midX
                XCTAssertLessThanOrEqual(renderedX, initialX - 0.1)
            }
            XCTAssertEqual(title.convert(title.bounds, to: stage).midX, titleX, accuracy: 0.01)
        }
        XCTAssertGreaterThan(Set(intermediate).count, 1)
        try select(.profiles)
        try await Task.sleep(for: .milliseconds(35))
        try select(.logs)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(try button(.logs).accessibilityValue() as? String, "已选中")
        let settled = views(host).compactMap { $0 as? RealitySurfaceAnchor }
        XCTAssertTrue(settled.contains { if case .well = $0.style.shape { return true }; return false })
        XCTAssertFalse(settled.contains { if case .cardPanel = $0.style.shape { return true }; return false })
        XCTAssertEqual(title.convert(title.bounds, to: stage).midX, titleX, accuracy: 0.01)
    }

    func testRingUpdatesOnlyItsVisibleIndexRange() throws {
        let scene = RealityWindowScene(), id = UUID()
        let frame = CGRect(x: 0, y: 0, width: 280, height: 280)
        func set(_ fraction: Double) { scene.update(id, frame: frame, visible: frame, style: .init(shape: .ring(fraction))) }
        set(0)
        let entity = try XCTUnwrap(scene.root.findEntity(named: "surface-" + id.uuidString) as? ModelEntity)
        let mesh = try XCTUnwrap(entity.model?.mesh.lowLevelMesh)
        XCTAssertEqual(mesh.parts.first?.indexCount, 0)
        mesh.withUnsafeBytes(bufferIndex: 0) { bytes in
            let stride = mesh.descriptor.vertexLayouts[0].bufferStride
            let start = bytes.loadUnaligned(as: SIMD3<Float>.self)
            let quarter = bytes.loadUnaligned(fromByteOffset: mesh.vertexCapacity / 4 * stride, as: SIMD3<Float>.self)
            XCTAssertEqual(start.x, 0, accuracy: 0.00001)
            XCTAssertLessThan(start.y, 0, "Start at six o'clock")
            XCTAssertLessThan(quarter.x, 0, "Reach nine o'clock after a quarter turn")
            XCTAssertEqual(quarter.y, 0, accuracy: 0.00001)
        }
        for percent in 1...100 { set(Double(percent)/100) }
        XCTAssertEqual(mesh.parts.first?.indexCount, mesh.indexCapacity)
        set(0.5)
        XCTAssertEqual(mesh.parts.first?.indexCount, mesh.indexCapacity/2)
        set(0)
        XCTAssertEqual(mesh.parts.first?.indexCount, 0, "The original buffer must reflect the final range")
        XCTAssertEqual(scene.meshBuilds, 1)
    }

    func testBundledControlsHaveDepthAndProgressKeepsOneFill() throws {
        for asset in ControlAsset.allCases {
            let mesh = try asset.mesh()
            XCTAssertGreaterThan(mesh.bounds.extents.z, 0, asset.rawValue)
        }
        let scene = RealityWindowScene(), id = UUID()
        let frame = CGRect(x: 0, y: 0, width: 200, height: 6)
        for value in [0.0, 0.25, 1, 0] {
            scene.update(id, frame: frame, visible: frame, style: .init(shape: .well(3), progress: value))
            let fill = try XCTUnwrap(scene.root.findEntity(named: ControlAsset.progressFill.rawValue) as? ModelEntity)
            XCTAssertEqual(fill.isEnabled, value > 0)
            XCTAssertEqual(fill.scale.x * (fill.model?.mesh.bounds.extents.x ?? 0), Float(value)*0.197, accuracy: 0.00001)
        }
        XCTAssertEqual(scene.meshBuilds, 1)
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
        model.routes = try JSONDecoder().decode([RoutingProfile].self, from: Data("""
        [{"id":"allow","remarks":"白名单","isActive":true},
         {"id":"deny","remarks":"黑名单","isActive":false},
         {"id":"all","remarks":"全局代理","isActive":false}]
        """.utf8))
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
            func content(bottomInset: CGFloat) -> some View {
                ContentView(initialPage: page).environmentObject(model)
                    .environment(\.dashboardVisibilityOverride, true)
                    .font(AppFont.body).buttonStyle(HoverButtonStyle()).environment(\.colorScheme, .dark)
                    .padding(.bottom, bottomInset)
                    .background(WindowTracker { _ in })
            }
            let host = NSHostingView(rootView: content(bottomInset: 0))
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
                func settingsScroll() -> NSScrollView? {
                    descendants(host).compactMap { $0 as? SettingsWheelScroll.Anchor }
                        .compactMap { $0.enclosingScrollView }.first { ($0.documentView?.bounds.height ?? 0) > 400 }
                }
                let overview = try XCTUnwrap(settingsScroll())
                let overviewHeight = try XCTUnwrap(overview.documentView).bounds.height
                XCTAssertLessThanOrEqual(overviewHeight, overview.contentView.bounds.height + 1,
                                         "Both footer cards should fit in the standard window")
                // Keep the full-size snapshot above. Exercise wheel motion and
                // RealityKit clipping in a deliberately shorter viewport.
                host.rootView = content(bottomInset: 96)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let scroll = try XCTUnwrap(settingsScroll())
                let document = try XCTUnwrap(scroll.documentView)
                let maxY = document.bounds.height - scroll.contentView.bounds.height
                XCTAssertGreaterThan(maxY, 30)
                let wheelAnchor = try XCTUnwrap(descendants(document).compactMap { $0 as? SettingsWheelScroll.Anchor }.first { $0.enclosingScrollView === scroll })
                let nativeWheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                    wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
                let wheelEvent = try XCTUnwrap(NSEvent(cgEvent: nativeWheel))
                let location = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                let origin = scroll.contentView.bounds.minY
                XCTAssertTrue(wheelAnchor.consume(wheelEvent, at: location))
                XCTAssertEqual(scroll.contentView.bounds.minY, origin)
                try await Task.sleep(for: .milliseconds(210))
                XCTAssertEqual(scroll.contentView.bounds.minY, min(maxY, origin + 3 * scroll.verticalLineScroll), accuracy: 1)
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
                        let fullFrame = anchor.convert(anchor.bounds, to: renderer)
                        let usesClip = RealityViewportClip.supported && anchor.style.viewportID != nil
                        let expected = RealityWindowScene.position(usesClip ? fullFrame : rect, viewport: renderer.bounds.size, level: anchor.style.level)
                        #if compiler(>=6.4)
                        if #available(macOS 27, *), usesClip, rect != fullFrame {
                            let clipping = try XCTUnwrap(entity.components[ClippingComponent.self])
                            XCTAssertEqual(clipping.bounds.max.y, Float(fullFrame.midY-rect.minY)/1000, accuracy: 0.00001)
                            XCTAssertEqual(clipping.bounds.min.y, Float(fullFrame.midY-rect.maxY)/1000, accuracy: 0.00001)
                        }
                        #endif
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
