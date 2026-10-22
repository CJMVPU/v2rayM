import AppKit
import SwiftUI

/// Two recessed tabs meet the top window edge; their actions retain normal macOS
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
                button.frame = NSRect(x: index * 28, y: 0, width: 24, height: 26)
                button.target = self
                button.action = role == .close ? #selector(closeWindow) : #selector(minimizeWindow)
                addSubview(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
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
            let shape = NSBezierPath()
            let left: CGFloat = 0.5, right = bounds.width - 0.5, bottom = bounds.height - 0.5
            shape.move(to: NSPoint(x: left, y: 0))
            shape.line(to: NSPoint(x: left, y: bottom - 9))
            shape.curve(to: NSPoint(x: left + 9, y: bottom), controlPoint1: NSPoint(x: left, y: bottom - 4), controlPoint2: NSPoint(x: left + 4, y: bottom))
            shape.line(to: NSPoint(x: right - 9, y: bottom))
            shape.curve(to: NSPoint(x: right, y: bottom - 9), controlPoint1: NSPoint(x: right - 4, y: bottom), controlPoint2: NSPoint(x: right, y: bottom - 4))
            shape.line(to: NSPoint(x: right, y: 0))
            shape.close()
            let tint = role == .close
                ? NSColor(calibratedRed: 1, green: 0.37, blue: 0.34, alpha: 1)
                : NSColor(calibratedRed: 1, green: 0.76, blue: 0.19, alpha: 1)
            tint.withAlphaComponent(isHighlighted ? 0.7 : hovered ? 1 : 0.9).setFill()
            shape.fill()
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            shape.lineWidth = 1; shape.stroke()
            let symbol = NSBezierPath()
            let x = bounds.midX, y: CGFloat = 12
            if role == .close {
                symbol.move(to: NSPoint(x: x - 3, y: y - 3)); symbol.line(to: NSPoint(x: x + 3, y: y + 3))
                symbol.move(to: NSPoint(x: x + 3, y: y - 3)); symbol.line(to: NSPoint(x: x - 3, y: y + 3))
            } else {
                symbol.move(to: NSPoint(x: x - 3.5, y: y)); symbol.line(to: NSPoint(x: x + 3.5, y: y))
            }
            NSColor.black.withAlphaComponent(hovered ? 0.9 : 0.7).setStroke()
            symbol.lineWidth = 1.2; symbol.lineCapStyle = .round; symbol.stroke()
        }
    }
}
