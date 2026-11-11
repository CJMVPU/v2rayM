import AppKit
import SwiftUI

/// Circular controls share the small title-bar switch's 16-point thumb diameter.
struct WindowControlButtons: NSViewRepresentable {
    static let diameter: CGFloat = 16
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) {}

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
        @objc private func closeWindow() { window?.performClose(nil) }
        @objc private func minimizeWindow() { window?.miniaturize(nil) }
    }

    final class RoundButton: NSButton {
        enum Role { case close, minimize }
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
            title = ""
            isBordered = false
            setButtonType(.momentaryChange)
            setAccessibilityLabel(role == .close ? "关闭窗口" : "最小化窗口")
            toolTip = role == .close ? "关闭窗口" : "最小化窗口"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
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
            guard isEnabled, window != nil,
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
        override func draw(_ dirtyRect: NSRect) {
            let rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            let highlight: NSColor = role == .close ? .systemRed : .systemYellow
            let level: CGFloat = isEnabled ? (isHighlighted ? 1 : hoverLevel) : 0
            if level > 0 {
                highlight.withAlphaComponent(0.22 * level).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3)).fill()
            }
            let base = !isEnabled ? NSColor(calibratedWhite: 0.28, alpha: 1)
                : NSColor(calibratedWhite: 0.66, alpha: 1).blended(withFraction: level, of: highlight)!
            (isHighlighted && isEnabled ? base.blended(withFraction: 0.18, of: .black)! : base).setFill()
            NSBezierPath(ovalIn: rect).fill()
            // Normal state is a quiet gray circle; hover reveals the action symbol.
            guard level > 0 else { return }
            let symbol = NSBezierPath()
            let x = rect.midX, y = rect.midY
            if role == .close {
                symbol.move(to: NSPoint(x: x - 2.5, y: y - 2.5)); symbol.line(to: NSPoint(x: x + 2.5, y: y + 2.5))
                symbol.move(to: NSPoint(x: x + 2.5, y: y - 2.5)); symbol.line(to: NSPoint(x: x - 2.5, y: y + 2.5))
            } else {
                symbol.move(to: NSPoint(x: x - 3, y: y)); symbol.line(to: NSPoint(x: x + 3, y: y))
            }
            NSColor(calibratedWhite: 0.12, alpha: level).setStroke()
            symbol.lineWidth = 1.2; symbol.lineCapStyle = .round; symbol.stroke()
        }
    }
}
