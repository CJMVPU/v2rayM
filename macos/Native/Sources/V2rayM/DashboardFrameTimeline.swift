import AppKit
import QuartzCore

/// A window-scoped native clock. Ticks do not publish SwiftUI state.
@MainActor final class DashboardDisplayClock: NSObject {
    private(set) var date: Date?
    var onFrame: ((Date) -> Void)?
    private var link: CADisplayLink?
    private weak var window: NSWindow?
    private var target: Target?
    private var requestedMaximum: Float?
    private var lifecycleBlocked = false
    var isRunning: Bool { link != nil }
    static func range(maximum: Int) -> CAFrameRateRange {
        let rate = Float(max(1, min(120, maximum)))
        return CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
    }
    func attach(window: NSWindow?, enabled: Bool) {
        guard enabled else { stop(); return }
        guard let window else { stop(); return }
        guard !lifecycleBlocked else { return }
        let range = Self.range(maximum: window.screen?.maximumFramesPerSecond ?? 60)
        if self.window === window, let link {
            if requestedMaximum != range.maximum { link.preferredFrameRateRange = range; requestedMaximum = range.maximum }
            return
        }
        stop(); self.window = window
        let target = Target(owner: self)
        let link = window.displayLink(target: target, selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = range
        self.target = target; self.link = link; requestedMaximum = range.maximum
        link.add(to: .main, forMode: .common)
    }
    func thaw() { lifecycleBlocked = false }
    func freeze() { lifecycleBlocked = true; stop() }
    func stop() { link?.invalidate(); link = nil; target = nil; window = nil; requestedMaximum = nil }
    private func frame(at date: Date) {
        self.date = date
        onFrame?(date)
    }
    @MainActor private final class Target: NSObject {
        weak var owner: DashboardDisplayClock?
        init(owner: DashboardDisplayClock) { self.owner = owner }
        @objc func tick(_ sender: CADisplayLink) {
            guard let owner, owner.link === sender, !owner.lifecycleBlocked else { return }
            owner.frame(at: Date())
        }
    }
}
