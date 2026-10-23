import XCTest
import AppKit
@testable import V2rayM

final class GlobeRenderingTests: XCTestCase {
    @MainActor func testOffscreenMap() throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_RENDER_OUTPUT"] else {
            throw XCTSkip("Set V2RAYM_RENDER_OUTPUT for a map snapshot")
        }
        AppFont.register()
        let size = CGSize(width: 568, height: 560)
        let view = PacificMapView(frame: CGRect(origin: .zero, size: size))
        var time = 100.0
        view.timeSource = { time }
        XCTAssertNil(view.toolTip)
        view.update(origin: GlobeOrigin.cities[0], node: GlobeOrigin.cities[6], connections: [], active: true,
                    upload: 1, download: 1, reduceMotion: false)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1136, pixelsHigh: 1120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        view.draw(view.bounds)
        time += 1.8
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        view.stop()
    }
}
