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
                    .realitySurface(.init(shape: .panel(9), depth: 3, level: 76,
                        highlighted: hovering, enabled: enabled, allowsFlip: !reduced, switchOn: configuration.isOn))
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 && enabled }
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
        .accessibilityRepresentation { Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) { configuration.label }.toggleStyle(.switch) }
    }
}

/// The field editor, IME, selection and secure-entry behavior remain AppKit's.
struct RealityTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(.horizontal, 7).padding(.vertical, 4)
            .modifier(RealityEditorSurface())
    }
}

/// The native editor remains first responder; the recess follows its focus.
struct RealityEditorSurface: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).realityField(highlighted: focused)
    }
}
