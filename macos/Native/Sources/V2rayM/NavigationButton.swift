import AppKit
import SwiftUI

struct NavigationButton: NSViewRepresentable {
    let label: String
    let enabled: Bool
    var circular = false
    var hoverChanged: ((Bool) -> Void)? = nil
    let action: (UnitPoint) -> Void

    final class Button: NSButton {
        var circular = false
        override func hitTest(_ point: NSPoint) -> NSView? {
            if circular && !NSBezierPath(ovalIn: frame).contains(point) { return nil }
            return super.hitTest(point)
        }
        override var isFlipped: Bool { true }
        var activate: ((UnitPoint) -> Void)?
        var hoverChanged: ((Bool) -> Void)?
        private var hoverTracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking); self.hoverTracking = nil }
            guard hoverChanged != nil else { return }
            let area = NSTrackingArea(rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
            addTrackingArea(area)
            hoverTracking = area
        }
        private func track(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            hoverChanged?(isEnabled && bounds.contains(point) && (!circular || NSBezierPath(ovalIn: bounds).contains(point)))
        }
        override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); track(event) }
        override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); track(event) }
        override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hoverChanged?(false) }
        private var clickLocation: UnitPoint?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private var pressed = false
        override func mouseDown(with event: NSEvent) { pressed = isEnabled }
        override func mouseUp(with event: NSEvent) {
            defer { pressed = false }
            if pressed && isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)) {
                let point = convert(event.locationInWindow, from: nil)
                if circular && !NSBezierPath(ovalIn: bounds).contains(point) { return }
                clickLocation = UnitPoint(x: point.x / bounds.width, y: point.y / bounds.height)
                sendAction(action, to: target)
                clickLocation = nil
            }
        }
        override func draw(_ dirtyRect: NSRect) {}
        @objc func clicked() { activate?(clickLocation ?? .center) }
    }
    func makeNSView(context: Context) -> Button {
        let button = Button(frame: .zero)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.target = button
        button.action = #selector(Button.clicked)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        let needsTracking = (button.hoverChanged == nil) != (hoverChanged == nil)
        button.hoverChanged = hoverChanged
        if needsTracking { button.updateTrackingAreas() }
        button.circular = circular
        button.activate = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = enabled
    }
}
