import AppKit
import SwiftUI
import V2rayMKit

struct PacificMap: NSViewRepresentable {
    let origin: GlobePlace?
    let node: GlobePlace?
    let connections: [GlobeConnection]
    let active: Bool
    let upload: Double
    let download: Double
    let reduceMotion: Bool
    func makeNSView(context: Context) -> PacificMapView { PacificMapView() }
    func updateNSView(_ view: PacificMapView, context: Context) {
        view.update(origin: origin, node: node, connections: connections, active: active,
                    upload: upload, download: download, reduceMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: PacificMapView, coordinator: ()) { view.stop() }
}

/// A flat, CPU-backed map: no hidden hemisphere, perspective occlusion, or GPU
/// requirement. The same drawing code is used by the app and snapshot check.
final class PacificMapView: NSView {
    private var origin: GlobePlace?
    private var node: GlobePlace?
    private var connections: [GlobeConnection] = []
    private var reduceMotion = false
    private var timer: Timer?
    private var particles = MapParticles()
    var timeSource: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var observers: [NSObjectProtocol] = []
    private var backgroundImage: CGImage?
    private var suspended = true
    private var mapKey = ""
    private let artwork = MapArtwork()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private let cyan = NSColor(calibratedRed: 0.02, green: 0.83, blue: 0.98, alpha: 1)
    private let purple = NSColor(calibratedRed: 0.72, green: 0.35, blue: 0.98, alpha: 1)
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("固定太平洋地图；视野外位置以边缘空心光点指示")
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.window else { return }
                if note.name == NSWindow.willCloseNotification { self.stop() } else { self.updatePlayback() }
            })
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePlayback() }
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    func stop() { timer?.invalidate(); timer = nil }
    private func updatePlayback() {
        let visible = window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        if !visible || reduceMotion || suspended { particles.suspend(now: timeSource()) }
        suspended = !visible || reduceMotion
        let animate = !particles.isIdle && !reduceMotion && visible
        if animate && timer == nil {
            timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.particles.advance(now: self.timeSource())
                self.needsDisplay = true
                if self.particles.isIdle { self.stop() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        } else if !animate { stop() }
    }
    func update(origin: GlobePlace?, node: GlobePlace?, connections: [GlobeConnection], active: Bool,
                upload: Double, download: Double, reduceMotion: Bool) {
        self.origin = origin; self.node = node
        self.reduceMotion = reduceMotion
        self.connections = Array(connections.filter {
            Date().timeIntervalSince($0.timestamp) < 20 && $0.place != nil && ($0.route == "proxy" || $0.route == "direct")
        }.prefix(8))
        let now = timeSource()
        var routes: [MapParticleRoute] = []
        if active && !reduceMotion {
            if let origin, let node {
                if upload > 0 { routes.append(.init(id: "upload", from: origin, to: node, style: .upload)) }
                if download > 0 { routes.append(.init(id: "download", from: node, to: origin, style: .download)) }
            }
            for item in self.connections {
                guard let end = item.place, let start = item.isProxy ? node : origin else { continue }
                let remaining = max(0, min(20, 20 - Date().timeIntervalSince(item.timestamp)))
                routes.append(.init(id: "target:" + item.id, from: start, to: end,
                                    style: item.isProxy ? .proxy : .direct, expiresAt: now + remaining))
            }
        }
        particles.update(routes: routes, now: now)
        updatePlayback(); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        NSColor(calibratedRed: 0.018, green: 0.042, blue: 0.075, alpha: 1).setFill(); bounds.fill()
        let projection = PacificMapProjection(size: bounds.size)
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(bounds.size)|\(scale)"
        if key != mapKey {
            mapKey = key
            backgroundImage = makeBackground(projection: projection, scale: scale)
        }
        if let backgroundImage {
            NSImage(cgImage: backgroundImage, size: bounds.size).draw(in: bounds, from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let now = timeSource()
        if !reduceMotion {
            particles.advance(now: now)
            for dot in particles.particles {
                let color: NSColor = dot.route.style == .download ? purple : dot.route.style == .direct ? .systemMint : cyan
                let curve = projection.curve(from: dot.route.from, to: dot.route.to, returnPath: dot.route.style == .download)
                marker(curve.point(at: dot.progress(at: now)), color: color.withAlphaComponent(dot.opacity(at: now)), radius: 2.4, hollow: projection.isOutside(dot.route.to))
            }
        }
        var occupied: [CGRect] = []
        if let origin { label((projection.isOutside(origin) ? "视野外 · " : "") + origin.displayCity, at: projection.displayPoint(origin), color: cyan, occupied: &occupied) }
        if let node { label((projection.isOutside(node) ? "视野外 · " : "") + node.displayCity, at: projection.displayPoint(node), color: purple, occupied: &occupied) }
    }
    private func makeBackground(projection: PacificMapProjection, scale: Double) -> CGImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(bounds.width * scale)),
            pixelsHigh: max(1, Int(bounds.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.translateBy(x: 0, y: bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        artwork.draw(in: bounds, land: artwork.path(projection: projection), projection: projection)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
    private func marker(_ point: CGPoint, color: NSColor, radius: CGFloat, hollow: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = color; shadow.shadowBlurRadius = 3; shadow.shadowOffset = .zero; shadow.set()
        color.setFill()
        let dot = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        if hollow { color.setStroke(); dot.lineWidth = 1.2; dot.stroke() } else { dot.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func label(_ text: String, at point: CGPoint, color: NSColor, occupied: inout [CGRect]) {
        marker(point, color: color, radius: 4)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: AppFont.postScriptName, size: 12) ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let string = text as NSString, size = string.size(withAttributes: attributes)
        let width = min(bounds.width - 16, size.width + 18), height: CGFloat = 27
        var rect = CGRect(x: min(bounds.maxX - width - 8, max(8, point.x + 8)), y: point.y - height / 2, width: width, height: height)
        if rect.maxY > bounds.maxY - 8 { rect.origin.y = point.y - height - 12 }
        if occupied.contains(where: { $0.intersects(rect) }) { rect.origin.y = max(8, point.y - height - 12) }
        occupied.append(rect)
        string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}

/// Cached ocean shading, graticule and coastline; geographic framing stays fixed.
private struct MapArtwork {
    private let polygons: [[[[Double]]]]
    init() {
        if let url = Bundle.module.url(forResource: "land-polygons", withExtension: "json", subdirectory: "Globe"),
           let data = try? Data(contentsOf: url),
           let value = try? JSONDecoder().decode([[[[Double]]]].self, from: data) {
            polygons = value
        } else { polygons = [] }
    }
    func path(projection: PacificMapProjection) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        for polygon in polygons {
            for offset in [-360.0, 0, 360] {
                for ring in polygon where ring.count > 2 {
                    var previous = ring[0][0]
                    for (index, coordinate) in ring.enumerated() {
                        var longitude = coordinate[0]
                        while longitude - previous > 180 { longitude -= 360 }
                        while longitude - previous < -180 { longitude += 360 }
                        previous = longitude
                        let point = CGPoint(
                            x: projection.plot.minX + (longitude + offset - projection.world.minX) / projection.world.width * projection.plot.width,
                            y: projection.plot.minY + (projection.world.maxY - PacificMapProjection.mercator(coordinate[1])) / projection.world.height * projection.plot.height)
                        if index == 0 { path.move(to: point) } else { path.line(to: point) }
                    }
                    path.close()
                }
            }
        }
        path.lineJoinStyle = .round
        return path
    }
    func draw(in bounds: CGRect, land: NSBezierPath?, projection: PacificMapProjection) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor(calibratedRed: 0.018, green: 0.042, blue: 0.075, alpha: 1).setFill(); bounds.fill()
        drawOcean(in: bounds, projection: projection)
        guard let land else { return }
        NSColor(calibratedRed: 0.045, green: 0.082, blue: 0.125, alpha: 1).setFill(); land.fill()
        NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.46, alpha: 0.75).setStroke()
        land.lineWidth = 0.65; land.stroke()
        land.addClip()
        let dots = NSBezierPath()
        for row in 0...Int(bounds.height / 7) {
            for column in 0...Int(bounds.width / 7) {
                let x = CGFloat(column) * 7 + (row.isMultiple(of: 2) ? 0 : 3.5)
                dots.appendOval(in: CGRect(x: x, y: CGFloat(row) * 7, width: 0.9, height: 0.9))
            }
        }
        NSColor(calibratedRed: 0.24, green: 0.40, blue: 0.55, alpha: 0.38).setFill(); dots.fill()
    }

    private func drawOcean(in bounds: CGRect, projection: PacificMapProjection) {
        // Draw beneath opaque land so the subtle geographic grid belongs to the
        // ocean. All of this stays in the cached background, outside animation.
        NSGradient(colors: [
            NSColor(calibratedRed: 0.027, green: 0.078, blue: 0.115, alpha: 1),
            NSColor(calibratedRed: 0.018, green: 0.042, blue: 0.075, alpha: 1)
        ])?.draw(in: NSBezierPath(rect: bounds), relativeCenterPosition: NSPoint(x: 0.05, y: 0.05))

        let grid = NSBezierPath()
        for longitude in stride(from: 0.0, through: 360.0, by: 20.0) {
            let x = projection.plot.minX + (longitude - projection.world.minX) / projection.world.width * projection.plot.width
            grid.move(to: CGPoint(x: x, y: bounds.minY))
            grid.line(to: CGPoint(x: x, y: bounds.maxY))
        }
        for latitude in stride(from: -80.0, through: 80.0, by: 20.0) {
            let y = projection.plot.minY + (projection.world.maxY - PacificMapProjection.mercator(latitude)) / projection.world.height * projection.plot.height
            grid.move(to: CGPoint(x: bounds.minX, y: y))
            grid.line(to: CGPoint(x: bounds.maxX, y: y))
        }
        NSColor(calibratedRed: 0.21, green: 0.37, blue: 0.48, alpha: 0.14).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()

        let center = projection.point(GlobePlace(city: "", latitude: 5, longitude: -170))
        for (text, size, spacing, offset) in [("太平洋", 16.0, 5.0, -12.0), ("PACIFIC OCEAN", 8.0, 2.0, 12.0)] {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: AppFont.postScriptName, size: size) ?? NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor(calibratedRed: 0.38, green: 0.53, blue: 0.64, alpha: 0.36),
                .kern: spacing
            ]
            let label = text as NSString
            let extent = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: center.x - extent.width / 2, y: center.y + offset - extent.height / 2), withAttributes: attributes)
        }
    }
}
