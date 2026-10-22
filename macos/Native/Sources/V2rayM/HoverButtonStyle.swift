import SwiftUI

/// One hover treatment for app buttons, including sheets; disabled controls stay inert.
struct HoverButtonStyle: ButtonStyle {
    var plain = false
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, plain: plain)
    }
    private struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        let plain: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(.horizontal, plain ? 0 : 7)
                .padding(.vertical, plain ? 0 : 2)
                .background {
                    if !plain {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(enabled && hovering ? 0.22 : 0.13))
                    }
                }
                .brightness(enabled && hovering ? (scheme == .dark ? 0.13 : -0.12) : 0)
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
