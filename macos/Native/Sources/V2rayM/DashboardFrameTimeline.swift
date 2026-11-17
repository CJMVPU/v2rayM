import AppKit
import QuartzCore
import SwiftUI

/// Only this small drawing subtree observes display ticks, not the whole home.
struct DashboardFrameTimeline<Content: View>: View {
    let enabled: Bool
    let fallback: Date
    @ViewBuilder let content: (Date) -> Content
    @StateObject private var clock = DashboardDisplayClock()
    var body: some View {
        content(clock.date ?? fallback)
            .background(DisplayClockAttachment(clock: clock, enabled: enabled))
    }
}

@MainActor final class DashboardDisplayClock: NSObject, ObservableObject {
    @Published private(set) var date: Date?
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
    @MainActor private final class Target: NSObject {
        weak var owner: DashboardDisplayClock?
        init(owner: DashboardDisplayClock) { self.owner = owner }
        @objc func tick(_ sender: CADisplayLink) { owner?.date = Date() }
    }
}

private struct DisplayClockAttachment: NSViewRepresentable {
    let clock: DashboardDisplayClock
    let enabled: Bool
    func makeNSView(context: Context) -> Attachment { Attachment(clock: clock) }
    func updateNSView(_ view: Attachment, context: Context) {
        view.enabled = enabled; clock.attach(window: view.window, enabled: enabled)
    }
    static func dismantleNSView(_ view: Attachment, coordinator: ()) { view.clock.stop() }
    final class Attachment: NSView {
        let clock: DashboardDisplayClock
        var enabled = false
        private var screenObserver: NSObjectProtocol?
        private var freezeObserver: NSObjectProtocol?
        private var thawObserver: NSObjectProtocol?
        init(clock: DashboardDisplayClock) { self.clock = clock; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
            if let freezeObserver { NotificationCenter.default.removeObserver(freezeObserver) }; freezeObserver = nil
            if let thawObserver { NotificationCenter.default.removeObserver(thawObserver) }; thawObserver = nil
            if let window {
                thawObserver = NotificationCenter.default.addObserver(forName: .dashboardDidThaw, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.clock.thaw(); self.clock.attach(window: self.window, enabled: self.enabled)
                    }
                }
                freezeObserver = NotificationCenter.default.addObserver(forName: .dashboardWillFreeze, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.clock.freeze() }
                }
                screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }; self.clock.attach(window: self.window, enabled: self.enabled)
                    }
                }
            }
            clock.attach(window: window, enabled: enabled)
        }
        deinit {
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            if let freezeObserver { NotificationCenter.default.removeObserver(freezeObserver) }
            if let thawObserver { NotificationCenter.default.removeObserver(thawObserver) }
        }
    }
}
