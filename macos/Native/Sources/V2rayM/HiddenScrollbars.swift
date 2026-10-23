import AppKit
import SwiftUI

/// Also covers AppKit-backed tables and editors, whose scrollers can ignore
/// SwiftUI's indicator preference when macOS is set to always show scrollbars.
struct HiddenScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) { view.scheduleUpdate() }

    final class Observer: NSView {
        private var pending = false
        private var windowUpdate: NSObjectProtocol?
        deinit {
            if let windowUpdate { NotificationCenter.default.removeObserver(windowUpdate) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let windowUpdate { NotificationCenter.default.removeObserver(windowUpdate) }
            windowUpdate = nil
            if let window {
                windowUpdate = NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    guard let self, let root = self.window?.contentView else { return }
                    self.hideScrollbars(in: root)
                }
            }
            scheduleUpdate()
        }
        override func layout() {
            super.layout()
            scheduleUpdate()
        }
        func scheduleUpdate() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                if let root = self.window?.contentView { self.hideScrollbars(in: root) }
            }
        }
        private func hideScrollbars(in view: NSView) {
            if let scroll = view as? NSScrollView {
                if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
                scroll.verticalScroller?.isHidden = true
                scroll.horizontalScroller?.isHidden = true
                if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
                if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
                scroll.autohidesScrollers = true
            }
            for child in view.subviews { hideScrollbars(in: child) }
        }
    }
}
