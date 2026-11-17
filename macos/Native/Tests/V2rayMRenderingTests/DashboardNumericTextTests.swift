import XCTest
import AppKit
import CoreImage
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
    func testVectorBlurRetainsGaussianGlyphAppearance() throws {
        AppFont.register()
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for size in [CGFloat(14), 24] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80,
                pixelsHigh: 90, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let drawing = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = drawing
            drawing.cgContext.scaleBy(x: 2, y: 2)
            ("8" as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: [
                .font: NSFont(name: AppFont.postScriptName, size: size)!, .foregroundColor: NSColor.cyan])
            NSGraphicsContext.restoreGraphicsState()
            let source = CIImage(cgImage: try XCTUnwrap(bitmap.cgImage))
            for radius in [1.3, 2.6, 4.0] {
                let previous = try XCTUnwrap(context.createCGImage(source.applyingFilter("CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: radius]), from: source.extent))
                let replacement = try XCTUnwrap(NumericLayerView.gaussianBlur(bitmap, radius: radius))
                XCTAssertEqual(replacement.width, previous.width)
                XCTAssertEqual(replacement.height, previous.height)
                let old = NSBitmapImageRep(cgImage: previous), new = NSBitmapImageRep(cgImage: replacement)
                var maximum = 0.0, total = 0.0
                for y in 0..<previous.height { for x in 0..<previous.width {
                    let delta = abs(old.colorAt(x: x, y: y)!.alphaComponent - new.colorAt(x: x, y: y)!.alphaComponent)
                    maximum = max(maximum, delta); total += delta
                } }
                print("Gaussian parity size=\(size) radius=\(radius): max=\(maximum) mean=\(total / Double(previous.width * previous.height))")
                XCTAssertLessThan(maximum, 0.05)
                XCTAssertLessThan(total / Double(previous.width * previous.height), 0.003)
            }
        }
    }

}
