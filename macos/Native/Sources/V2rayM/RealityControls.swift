import SwiftUI
import AppKit

struct RealityToggleStyle: ToggleStyle {
    var showsLabel = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                if showsLabel { configuration.label }
                Color.clear.frame(width: 30, height: 18)
                    .realitySurface(.init(shape: .panel(9),
                        color: configuration.isOn ? NSColor(DashboardTheme.cyan) : NSColor(calibratedWhite: 0.26, alpha: 1),
                        depth: 3, level: 76, highlighted: hovering, enabled: enabled))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Color.clear.frame(width: 14, height: 14)
                            .realitySurface(.init(shape: .disc, color: NSColor(calibratedWhite: 0.85, alpha: 1),
                                depth: 4, level: 80, enabled: enabled))
                            .padding(2)
                    }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 && enabled }
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
        .animation(reduced ? nil : .easeInOut(duration: 0.16), value: configuration.isOn)
    }
}

/// The field editor, IME, selection and secure-entry behavior remain AppKit's.
struct RealityTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(.horizontal, 7).padding(.vertical, 4)
            .realitySurface(.init(shape: .panel(5), color: NSColor(calibratedWhite: 0.12, alpha: 1), depth: 2, level: 25))
    }
}
