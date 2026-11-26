import QuartzCore
import SwiftUI
import XCTest
@testable import V2rayM

final class PageTurnTests: XCTestCase {
    @MainActor func testSlowNodeEditorKeepsSourceVisibleUntilReady() async throws {
        let navigation = PageCubeNavigation()
        func page(_ id: Page) -> AnyView {
            AnyView(RealityWindow {
                PageTurnHost(page: id, navigation: navigation) {
                    Text(id.rawValue).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.environment(\.dashboardVisibilityOverride, true))
        }
        let host = NSHostingView(rootView: page(.home))
        let window = NSWindow(contentRect: CGRect(x: 70, y: 70, width: 400, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { navigation.cancel(); window.close() }
        try await Task.sleep(for: .milliseconds(220))
        var finished = false
        navigation.turn(to: .profiles, mount: { host.rootView = page(.profiles); return true },
                        finished: { finished = true })
        let deadline = ContinuousClock.now + .seconds(2)
        while navigation.view?.page != .profiles, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(150))
        let overlay = try XCTUnwrap(navigation.view?.subviews.compactMap { $0 as? PageCubeOverlay }.first)
        let cube = try XCTUnwrap(overlay.layer?.sublayers?.first as? CATransformLayer)
        XCTAssertFalse(finished)
        XCTAssertEqual(cube.sublayers?.count, 1)
        XCTAssertNotNil(cube.sublayers?.first?.contents)
        XCTAssertNil(cube.animation(forKey: "pageTurn"))
        navigation.editorDidLoad()
        let end = ContinuousClock.now + .seconds(2)
        while !finished, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(finished)
        XCTAssertNil(overlay.superview)
    }

    func testFacesShareTheSameEdgeThroughoutBothQuarterTurns() {
        let width: CGFloat = 860, half = width / 2
        func point(_ x: CGFloat, _ t: CATransform3D) -> CGPoint {
            CGPoint(x: t.m11*x + t.m41, y: t.m13*x + t.m43)
        }
        for returning in [true, false] {
            let direction: CGFloat = returning ? -1 : 1
            for step in 0...20 {
                let turn = PageCube.rotation(progress: CGFloat(step)/20, width: width, returning: returning)
                let front = CATransform3DConcat(CATransform3DMakeTranslation(0, 0, half), turn)
                let side = CATransform3DConcat(PageCube.side(width: width, returning: returning), turn)
                let seam = point(direction * half, front), mate = point(-direction * half, side)
                XCTAssertEqual(seam.x, mate.x, accuracy: 0.001)
                XCTAssertEqual(seam.y, mate.y, accuracy: 0.001)
                if step == 0 { XCTAssertEqual(point(0, front), .zero) }
                if step == 20 {
                    XCTAssertEqual(point(0, side).x, 0, accuracy: 0.001)
                    XCTAssertEqual(point(half, side).x, half, accuracy: 0.001)
                }
            }
        }
    }
}
