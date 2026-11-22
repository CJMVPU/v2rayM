import AppKit
import SwiftUI

struct NavigationButton: NSViewRepresentable {
    let label: String
    let enabled: Bool
    var circular = false
    let action: (UnitPoint) -> Void

    final class Button: NSButton {
        var circular = false
        override func hitTest(_ point: NSPoint) -> NSView? {
            if circular && !NSBezierPath(ovalIn: frame).contains(point) { return nil }
            return super.hitTest(point)
        }
        override var isFlipped: Bool { true }
        var activate: ((UnitPoint) -> Void)?
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
        button.circular = circular
        button.activate = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = enabled
    }
}
