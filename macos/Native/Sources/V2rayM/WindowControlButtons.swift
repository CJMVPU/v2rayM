import AppKit
import SwiftUI

/// Circular controls share the small title-bar switch's 16-point thumb diameter.
struct WindowControlButtons: NSViewRepresentable {
    @Environment(\.realityScene) private var scene
    static let diameter: CGFloat = 16
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) {
        for button in view.subviews.compactMap({ $0 as? RoundButton }) { button.sceneOwner = scene; button.updateSurface() }
    }

    final class ControlsView: NSView {
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override init(frame: NSRect) {
            super.init(frame: frame)
            for role in [RoundButton.Role.close, .minimize] {
                let button = RoundButton(role: role)
                button.target = self
                button.action = role == .close ? #selector(closeWindow) : #selector(minimizeWindow)
                addSubview(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func layout() {
            super.layout()
            for (index, button) in subviews.enumerated() {
                button.frame = NSRect(x: CGFloat(index) * 26, y: (bounds.height - 24) / 2, width: 24, height: 24)
            }
        }
        @objc private func closeWindow() {
            WindowMinimizeCoordinator.shared.cancel(for: window)
            window?.performClose(nil)
        }
        @objc private func minimizeWindow() {
            guard let window else { return }
            subviews.compactMap { $0 as? RoundButton }.forEach { $0.settleHover() }
            WindowMinimizeCoordinator.shared.request(window)
        }
    }

    final class RoundButton: NSButton {
        enum Role { case close, minimize }
        weak var sceneOwner: RealityWindowScene?
        private let surface = RealitySurfaceAnchor()
        private let mark = RealitySurfaceAnchor()
        private let role: Role
        private var hovered = false
        private var hoverLevel: CGFloat = 0
        private var hoverTimer: Timer?
        private var transitionStart = 0.0
        private var transitionFrom: CGFloat = 0
        private var transitionTo: CGFloat = 0
        private var transitionDuration = 0.24
        private var hoverTracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        init(role: Role) {
            self.role = role
            super.init(frame: .zero)
            addSubview(surface); addSubview(mark)
            title = ""
            isBordered = false
            setButtonType(.momentaryChange)
            setAccessibilityLabel(role == .close ? "关闭窗口" : "最小化窗口")
            toolTip = role == .close ? "关闭窗口" : "最小化窗口"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func layout() {
            super.layout()
            surface.frame = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            mark.frame = NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)
            updateSurface()
        }
        func updateSurface() {
            let level: CGFloat = isEnabled ? (isHighlighted ? 1 : hoverLevel) : 0
            let highlight: NSColor = role == .close ? .systemRed : .systemYellow
            let color = NSColor(calibratedWhite: 0.66, alpha: 1).blended(withFraction: level, of: highlight)!
            surface.configure(scene: sceneOwner, style: .init(shape: .disc, color: color, depth: 4, level: 90, highlighted: level > 0, enabled: isEnabled))
            let ink = color.blended(withFraction: level, of: NSColor(white: 0.09, alpha: 1)) ?? color
            mark.configure(scene: sceneOwner, style: .init(shape: .glyph(role == .close ? .close : .minimize),
                color: ink, depth: 0.8, level: 93, visible: level > 0))
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self)
            addTrackingArea(area); hoverTracking = area
            updateHoverFromPointer()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateTrackingAreas()
            if window == nil {
                hoverTimer?.invalidate(); hoverTimer = nil
                hovered = false; hoverLevel = 0
            }
        }
        deinit { hoverTimer?.invalidate() }
        func settleHover() {
            hoverTimer?.invalidate(); hoverTimer = nil
            hovered = false; hoverLevel = 0; needsDisplay = true
        }
        private func setHovered(_ value: Bool) {
            guard hovered != value else { return }
            hovered = value
            animateHover()
        }
        private func animateHover() {
            // Start from the displayed value so rapid direction changes never jump.
            hoverTimer?.invalidate(); hoverTimer = nil
            transitionFrom = hoverLevel
            transitionTo = hovered && isEnabled ? 1 : 0
            guard isEnabled, let window,
                  !WindowMinimizeCoordinator.shared.isPreparing(window),
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                hoverLevel = transitionTo; needsDisplay = true
                return
            }
            guard transitionFrom != transitionTo else { return }
            transitionStart = ProcessInfo.processInfo.systemUptime
            transitionDuration = hovered ? 0.24 : 0.18
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    let t = min(1, max(0, (ProcessInfo.processInfo.systemUptime - self.transitionStart) / self.transitionDuration))
                    let eased = CGFloat(t * t * (3 - 2 * t))
                    self.hoverLevel = self.transitionFrom + (self.transitionTo - self.transitionFrom) * eased
                    self.needsDisplay = true
                    if t >= 1 { timer.invalidate(); self.hoverTimer = nil }
                }
            }
            hoverTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        private func updateHoverFromPointer() {
            let inside = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
            setHovered(inside)
        }
        override var isEnabled: Bool { didSet { animateHover(); needsDisplay = true } }
        override func mouseMoved(with event: NSEvent) { updateHoverFromPointer() }
        override func mouseEntered(with event: NSEvent) { setHovered(true) }
        override func mouseExited(with event: NSEvent) { setHovered(false) }
        override func draw(_ dirtyRect: NSRect) { updateSurface() }
    }
}
