import XCTest
import AppKit
@testable import V2rayM

@MainActor final class DashboardNumericTextTests: XCTestCase {
    func testGlyphsAreReusedAcrossRepeatedTicksAndDigitPositions() {
        AppFont.register()
        let view = NumericLayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        view.update("12.3", size: 14, color: .cyan, animate: true)
        let builds = view.glyphBuilds
        for _ in 0..<600 { view.update("12.3", size: 14, color: .cyan, animate: true) }
        XCTAssertEqual(view.glyphBuilds, builds)
        XCTAssertEqual(view.transitionCount, 0)
        view.update("32.1", size: 14, color: .cyan, animate: true)
        XCTAssertEqual(view.glyphBuilds, builds)
        XCTAssertEqual(view.transitionCount, 1)
        view.update("32.1", size: 14, color: .cyan, animate: false)
        XCTAssertTrue(view.layer!.sublayers!.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }
    func testFreezeRejectsLateUpdatesAndThawRestoresLatestSmoothly() {
        let view = NumericLayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        view.update("12.3", size: 14, color: .cyan, animate: true)
        view.update("32.1", size: 14, color: .cyan, animate: true)
        view.freeze()
        let builds = view.glyphBuilds, transitions = view.transitionCount
        for _ in 0..<20 { view.update("99.9", size: 14, color: .cyan, animate: true) }
        XCTAssertEqual(view.glyphBuilds, builds)
        XCTAssertEqual(view.transitionCount, transitions)
        XCTAssertTrue(view.layer!.sublayers!.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        view.thaw()
        view.update("99.9", size: 14, color: .cyan, animate: true)
        XCTAssertEqual(view.transitionCount, transitions + 1)
        XCTAssertEqual(view.glyphBuilds, builds + 1)
    }
    func testImmediateUpdatesAndStyleChangesDoNotAnimate() {
        let view = NumericLayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        view.update("12", size: 14, color: .cyan, animate: false)
        view.update("34", size: 14, color: .cyan, animate: false)
        view.update("34", size: 24, color: .orange, animate: true)
        XCTAssertEqual(view.transitionCount, 0)
        XCTAssertEqual(view.layer?.sublayers?.count, 2)
    }
}
