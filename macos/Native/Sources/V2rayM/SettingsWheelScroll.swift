import SwiftUI
import AppKit
import V2rayMKit

/// Installed inside the scrolling document so its nearest scroll ancestor
/// is the one that owns these settings, including inside an editor or popover.
struct SettingsWheelScroll: NSViewRepresentable {
    final class Anchor: NSView {
        private let wheel = SmoothWheelScroll()
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window === event.window else { return event }
                    return self.consume(event, at: event.locationInWindow) ? nil : event
                }
            }
        }
        func consume(_ event: NSEvent, at location: NSPoint) -> Bool {
            guard let scroll = enclosingScrollView, let content = window?.contentView,
                  scroll.visibleRect.contains(scroll.convert(location, from: nil)) else { return false }
            let point = content.superview?.convert(location, from: nil) ?? location
            var hit = content.hitTest(point)
            while let view = hit, view !== scroll {
                if let inner = view as? NSScrollView, let document = inner.documentView,
                   (event.scrollingDeltaX != 0 && document.bounds.width > inner.contentView.bounds.width ||
                    event.scrollingDeltaY != 0 && document.bounds.height > inner.contentView.bounds.height) { return false }
                hit = view.superview
            }
            return hit === scroll && wheel.handle(event, in: scroll)
        }
        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            wheel.cancel()
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor(frame: .zero) }
    func updateNSView(_ view: Anchor, context: Context) {}
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }
}
