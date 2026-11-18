import AppKit

/// Short, interruptible movement for a detented mouse wheel. Pixel-precise
/// devices already deliver a continuous stream with native momentum.
@MainActor public final class SmoothWheelScroll {
    private struct Movement {
        let start: CGPoint
        let target: CGPoint
        let time: TimeInterval
    }
    private weak var scroll: NSScrollView?
    private var movement: Movement?
    private var timer: Timer?
    public var isMoving: Bool { movement != nil }

    public init() {}

    public func handle(_ event: NSEvent, in scroll: NSScrollView) -> Bool {
        guard !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cancel()
            return false
        }
        // AppKit already maps Shift-wheel to the horizontal axis.
        let delta = CGPoint(x: -event.scrollingDeltaX * max(1, scroll.horizontalLineScroll),
                            y: (scroll.contentView.isFlipped ? -1 : 1) * event.scrollingDeltaY * max(1, scroll.verticalLineScroll))
        return move(in: scroll, by: delta, at: ProcessInfo.processInfo.systemUptime)
    }

    @discardableResult func move(in scroll: NSScrollView, by delta: CGPoint, at time: TimeInterval) -> Bool {
        if self.scroll !== scroll { cancel() }
        self.scroll = scroll
        let clip = scroll.contentView
        let previous = movement?.target ?? clip.bounds.origin
        var proposed = clip.bounds
        proposed.origin = CGPoint(x: previous.x + delta.x, y: previous.y + delta.y)
        let target = clip.constrainBoundsRect(proposed).origin
        guard target != previous else { return movement != nil }
        movement = Movement(start: clip.bounds.origin, target: target, time: time)
        guard timer == nil else { return true }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(at: ProcessInfo.processInfo.systemUptime) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func advance(at time: TimeInterval) {
        guard let scroll, let movement else { cancel(); return }
        let t = min(1, max(0, (time - movement.time) / 0.16))
        let progress = 1 - pow(1 - t, 3)
        let clip = scroll.contentView
        var rect = clip.bounds
        rect.origin = CGPoint(x: movement.start.x + progress * (movement.target.x - movement.start.x),
                              y: movement.start.y + progress * (movement.target.y - movement.start.y))
        clip.scroll(to: clip.constrainBoundsRect(rect).origin)
        scroll.reflectScrolledClipView(clip)
        if t == 1 { cancel() }
    }
    public func cancel() {
        timer?.invalidate()
        timer = nil
        movement = nil
    }
    deinit { timer?.invalidate() }
}
