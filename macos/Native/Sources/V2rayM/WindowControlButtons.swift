import AppKit
import SwiftUI

/// Two rounded controls centered in the title bar; their actions retain normal macOS
/// close-to-menu-bar and minimize behavior.
struct WindowControlButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) {}

    final class ControlsView: NSView {
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override init(frame: NSRect) {
            super.init(frame: frame)
            for (index, role) in [RecessedButton.Role.close, .minimize].enumerated() {
                let button = RecessedButton(role: role)
                button.frame = NSRect(x: index * 34, y: 0, width: 28, height: 28)
                button.target = self
                button.action = role == .close ? #selector(closeWindow) : #selector(minimizeWindow)
                addSubview(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func layout() {
            super.layout()
            for (index, button) in subviews.enumerated() {
                button.frame = NSRect(x: CGFloat(index) * 34, y: (bounds.height - 28) / 2, width: 28, height: 28)
            }
        }
        @objc private func closeWindow() { window?.performClose(nil) }
        @objc private func minimizeWindow() { window?.miniaturize(nil) }
    }

    final class RecessedButton: NSButton {
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
            let rect = bounds.insetBy(dx: 1.5, dy: 2)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            let base = role == .close ? NSColor(calibratedRed: 0.80, green: 0.53, blue: 0.55, alpha: 1)
                                      : NSColor(calibratedRed: 0.87, green: 0.78, blue: 0.50, alpha: 1)
            let tone = !isEnabled ? NSColor(calibratedWhite: 0.26, alpha: 1)
                       : isHighlighted ? base.blended(withFraction: 0.25, of: .black)!
                       : hovered ? base.blended(withFraction: 0.15, of: .white)! : base
            NSGradient(colors: [tone.blended(withFraction: 0.25, of: .black)!, tone])?.draw(in: shape, angle: 90)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            shape.lineWidth = 3; shape.stroke()
            NSGraphicsContext.restoreGraphicsState()
            let lip = NSBezierPath()
            lip.move(to: NSPoint(x: rect.minX + 5, y: rect.maxY - 0.6))
            lip.line(to: NSPoint(x: rect.maxX - 5, y: rect.maxY - 0.6))
            NSColor.white.withAlphaComponent(0.3).setStroke(); lip.lineWidth = 0.8; lip.stroke()
            let strength: CGFloat = isEnabled ? 0.9 : 0.3
            let symbol = NSBezierPath()
            let x = rect.midX, y = rect.midY
            if role == .close {
                symbol.move(to: NSPoint(x: x - 3.5, y: y - 3.5)); symbol.line(to: NSPoint(x: x + 3.5, y: y + 3.5))
                symbol.move(to: NSPoint(x: x + 3.5, y: y - 3.5)); symbol.line(to: NSPoint(x: x - 3.5, y: y + 3.5))
            } else {
                symbol.move(to: NSPoint(x: x - 4.5, y: y)); symbol.line(to: NSPoint(x: x + 4.5, y: y))
            }
            let highlight = symbol.copy() as! NSBezierPath
            var transform = AffineTransform(); transform.translate(x: 0, y: 1)
            highlight.transform(using: transform)
            NSColor(calibratedWhite: 0.75, alpha: strength).setStroke()
            highlight.lineWidth = 1.6; highlight.stroke()
            NSColor(calibratedWhite: 0.015, alpha: 1).setStroke()
            symbol.lineWidth = 1.5; symbol.lineCapStyle = .round; symbol.stroke()
        }
    }
}
