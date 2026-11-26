import AppKit
import QuartzCore

/// Two perpendicular faces rotate as a single solid. Moving the pivot back
/// keeps the shared vertical edge inside the viewport throughout the turn.
enum PageCube {
    static func rotation(progress: CGFloat, width: CGFloat, returning: Bool) -> CATransform3D {
        let angle = min(1, max(0, progress)) * .pi / 2
        let retreat = -width / 2 * (sin(angle) + cos(angle))
        return CATransform3DRotate(CATransform3DMakeTranslation(0, 0, retreat), returning ? angle : -angle, 0, 1, 0)
    }

    static func side(width: CGFloat, returning: Bool) -> CATransform3D {
        let sign: CGFloat = returning ? -1 : 1
        return CATransform3DRotate(CATransform3DMakeTranslation(sign * width / 2, 0, 0), sign * .pi / 2, 0, 1, 0)
    }
}

@MainActor final class PageCubeOverlay: NSView {
    private let cube = CATransformLayer()
    private let front = CALayer()
    private var cursorTimer: Timer?
    private var cursorIndex = 0
    private var appliedCursor: NSCursor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func cover(with image: CGImage) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = NSColor(DashboardTheme.background).cgColor
        var camera = CATransform3DIdentity
        camera.m34 = -1 / max(1, bounds.width * 1.6)
        layer.sublayerTransform = camera
        cube.frame = bounds
        layer.addSublayer(cube)
        front.bounds = bounds
        front.position = CGPoint(x: bounds.midX, y: bounds.midY)
        front.contents = image
        front.isDoubleSided = false
        front.transform = CATransform3DMakeTranslation(0, 0, bounds.width / 2)
        cube.addSublayer(front)
        cube.transform = PageCube.rotation(progress: 0, width: bounds.width, returning: false)
        CATransaction.commit()
    }

    func rotate(to image: CGImage, returning: Bool) async {
        await withCheckedContinuation { continuation in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { continuation.resume() }
            let side = CALayer()
            side.bounds = front.bounds
            side.position = front.position
            side.isDoubleSided = false
            side.contents = image
            side.transform = PageCube.side(width: bounds.width, returning: returning)
            cube.addSublayer(side)
            let steps = 64
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = (0...steps).map { i in
                NSValue(caTransform3D: PageCube.rotation(progress: CGFloat(i) / CGFloat(steps), width: bounds.width, returning: returning))
            }
            animation.duration = 0.44
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cube.transform = PageCube.rotation(progress: 1, width: bounds.width, returning: returning)
            cube.add(animation, forKey: "pageTurn")
            CATransaction.commit()
        }
    }

    private static let cursors: [NSCursor] = (0..<12).map { phase in
        let arrow = NSCursor.arrow
        let size = CGSize(width: arrow.image.size.width + 10, height: max(24, arrow.image.size.height))
        let image = NSImage(size: size, flipped: false) { rect in
            arrow.image.draw(at: CGPoint(x: 0, y: rect.height - arrow.image.size.height), from: .zero,
                             operation: .sourceOver, fraction: 1)
            for spoke in 0..<12 {
                let a = Double(spoke) * .pi / 6
                let center = CGPoint(x: rect.maxX - 8, y: 8)
                let dot = NSBezierPath(ovalIn: CGRect(x: center.x + 5*cos(a)-1.3, y: center.y - 5*sin(a)-1.3,
                                                       width: 2.6, height: 2.6))
                NSColor(white: 1, alpha: 1 - CGFloat((phase - spoke + 12) % 12) / 16).setFill()
                dot.fill()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: arrow.hotSpot)
    }
    func startCursor() {
        advanceCursor()
        let timer = Timer(timeInterval: 1/12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }
    private func advanceCursor() {
        guard let window, window.isKeyWindow,
              bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { restoreCursor(); return }
        let cursor = Self.cursors[cursorIndex]
        cursorIndex = (cursorIndex + 1) % Self.cursors.count
        cursor.set()
        appliedCursor = cursor
    }
    private func restoreCursor() {
        if let appliedCursor, NSCursor.current === appliedCursor { NSCursor.arrow.set() }
        appliedCursor = nil
    }
    func stopCursor() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        restoreCursor()
        if let window { window.invalidateCursorRects(for: self) }
    }
}
