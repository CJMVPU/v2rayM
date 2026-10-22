#!/usr/bin/env swift
import AppKit

// A vector-drawn, monochrome V with a shaded face and extruded edge.
// Regenerate with: swift scripts/render-macos-icon.swift macos/Native/Assets
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "macos/Native/Assets", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
context.translateBy(x: 0, y: 1024)
context.scaleBy(x: 1, y: -1)
func gray(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: value, green: value, blue: value, alpha: alpha)
}
func polygon(_ points: [(CGFloat, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for (x, y) in points.dropFirst() { path.addLine(to: CGPoint(x: x, y: y)) }
    path.closeSubpath()
    return path
}
func shade(_ path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path); context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}
let tile = CGPath(roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928), cornerWidth: 204, cornerHeight: 204, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: gray(0, 0.18))
context.addPath(tile); context.setFillColor(gray(0.96)); context.fillPath()
context.restoreGState()
shade(tile, colors: [gray(1), gray(0.995), gray(0.91)], from: CGPoint(x: 400, y: 70), to: CGPoint(x: 680, y: 976))
context.addPath(tile); context.setStrokeColor(gray(1, 0.85)); context.setLineWidth(3); context.strokePath()

let points: [(CGFloat, CGFloat)] = [(248, 260), (400, 260), (512, 588), (624, 260), (776, 260), (588, 764), (436, 764)]
let face = polygon(points)
let extrusion = polygon(points.map { ($0.0 + 16, $0.1 + 22) })
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 14), blur: 24, color: gray(0, 0.26))
context.addPath(extrusion); context.setFillColor(gray(0.12)); context.fillPath()
context.restoreGState()
shade(polygon([(776, 260), (792, 282), (604, 786), (588, 764)]),
      colors: [gray(0.35), gray(0.10)], from: CGPoint(x: 770, y: 300), to: CGPoint(x: 590, y: 780))
shade(polygon([(436, 764), (588, 764), (604, 786), (452, 786)]),
      colors: [gray(0.14), gray(0.32)], from: CGPoint(x: 436, y: 764), to: CGPoint(x: 604, y: 786))
shade(face, colors: [gray(0.19), gray(0.035), gray(0.11)], from: CGPoint(x: 300, y: 250), to: CGPoint(x: 700, y: 780))
context.addPath(face); context.setStrokeColor(gray(0, 0.75)); context.setLineWidth(2); context.strokePath()
context.move(to: CGPoint(x: 253, y: 262)); context.addLine(to: CGPoint(x: 398, y: 262))
context.move(to: CGPoint(x: 626, y: 262)); context.addLine(to: CGPoint(x: 772, y: 262))
context.setStrokeColor(gray(0.65, 0.5)); context.setLineWidth(2); context.strokePath()

let png = output.appendingPathComponent("AppIcon.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: png)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("Icon conversion failed") }
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = String(size * scale)
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try run("/usr/bin/sips", ["-z", pixels, pixels, png.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path])
print("Rendered AppIcon.png and AppIcon.icns")
