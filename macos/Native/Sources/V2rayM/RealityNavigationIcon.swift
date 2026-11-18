import AppKit
import SwiftUI

/// Bundled multi-part models, not extruded two-dimensional symbol outlines.
struct RealityNavigationIcon: View {
    let symbol: RealityNavigationSymbol
    let selected: Bool
    let label: String
    let activate: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var hovered = false
    @State private var flipToken = 0
    var body: some View {
        Color.clear.frame(width: 22, height: 22)
            .background {
                RealitySurface(style: .init(shape: .symbol(symbol),
                    depth: 3, level: 70, highlighted: enabled && hovered, selected: selected, enabled: enabled,
                    flipToken: flipToken, allowsFlip: !reduced && enabled))
            }
            .frame(width: 40, height: 24).contentShape(Rectangle())
            .overlay {
                NavigationButton(label: label, selected: selected, enabled: enabled) {
                    if enabled && !reduced { flipToken += 1 }
                    activate()
                }
            }
            .onHover { inside in
                if inside && !hovered && enabled && !reduced { flipToken += 1 }
                hovered = inside && enabled
            }
    }
}

/// A stationary native hit target owns every activation, including reselection.
private struct NavigationButton: NSViewRepresentable {
    let label: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    final class Button: NSButton {
        var activate: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private var pressed = false
        override func mouseDown(with event: NSEvent) { pressed = isEnabled }
        override func mouseUp(with event: NSEvent) {
            defer { pressed = false }
            if pressed && isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)) {
                sendAction(action, to: target)
            }
        }
        override func draw(_ dirtyRect: NSRect) {}
        @objc func clicked() { activate?() }
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
        button.activate = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(selected ? "已选中" : "未选中")
        button.isEnabled = enabled
    }
}
