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
            let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            addTrackingArea(area); hoverTracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            let rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            let highlight: NSColor = role == .close ? .systemRed : .systemYellow
            let base = !isEnabled ? NSColor(calibratedWhite: 0.28, alpha: 1)
                : hovered || isHighlighted ? highlight : NSColor(calibratedWhite: 0.66, alpha: 1)
            (isHighlighted && isEnabled ? base.blended(withFraction: 0.18, of: .black)! : base).setFill()
            NSBezierPath(ovalIn: rect).fill()
            // Normal state is a quiet gray circle; hover reveals the action symbol.
            guard isEnabled && (hovered || isHighlighted) else { return }
            let symbol = NSBezierPath()
            let x = rect.midX, y = rect.midY
            if role == .close {
                symbol.move(to: NSPoint(x: x - 2.5, y: y - 2.5)); symbol.line(to: NSPoint(x: x + 2.5, y: y + 2.5))
                symbol.move(to: NSPoint(x: x + 2.5, y: y - 2.5)); symbol.line(to: NSPoint(x: x - 2.5, y: y + 2.5))
            } else {
                symbol.move(to: NSPoint(x: x - 3, y: y)); symbol.line(to: NSPoint(x: x + 3, y: y))
            }
            NSColor(calibratedWhite: 0.12, alpha: 1).setStroke()
            symbol.lineWidth = 1.2; symbol.lineCapStyle = .round; symbol.stroke()
        }
    }
}
