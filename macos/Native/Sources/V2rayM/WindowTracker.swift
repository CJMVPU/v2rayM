import SwiftUI
import AppKit

struct WindowTracker: NSViewRepresentable {
    let capture: (NSWindow) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(capture: capture) }
    func updateNSView(_ view: TrackingView, context: Context) {}
    final class TrackingView: NSView {
        let capture: (NSWindow) -> Void
        init(capture: @escaping (NSWindow) -> Void) { self.capture = capture; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                capture(window)
                // SwiftUI finishes applying the scene's window style after attachment.
                DispatchQueue.main.async { [weak self] in self?.lockWindowSize() }
            }
        }
        override func layout() {
            super.layout()
            lockWindowSize()
        }
        private func lockWindowSize() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            let size = NSSize(width: 860, height: 600)
            if window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            if window.minSize != size { window.minSize = size }
            if window.maxSize != size { window.maxSize = size }
            if window.frame.size != size {
                var frame = window.frame; frame.size = size
                window.setFrame(frame, display: false)
            }
        }
    }
}
