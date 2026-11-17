import AppKit
import SwiftUI

/// Bundled multi-part models, not extruded two-dimensional symbol outlines.
struct RealityNavigationIcon: View {
    let symbol: RealityNavigationSymbol
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var hovered = false
    @State private var flipToken = 0
    var body: some View {
        Color.clear.frame(width: 26, height: 26)
            .background {
                RealitySurface(style: .init(shape: .symbol(symbol),
                    color: NSColor(selected ? DashboardTheme.cyan : DashboardTheme.muted),
                    depth: 3, level: 70, highlighted: enabled && (hovered || selected), enabled: enabled,
                    angle: enabled && hovered ? -36 : -27, tilt: enabled && hovered ? 23 : 18,
                    flipToken: flipToken, allowsFlip: !reduced && enabled))
            }
            .frame(width: 44, height: 29).contentShape(Rectangle())
            .onHover { inside in
                if inside && !hovered && enabled && !reduced { flipToken += 1 }
                hovered = inside && enabled
            }
            .onChange(of: selected) { _, selected in
                if selected && enabled && !reduced { flipToken += 1 }
            }
            .accessibilityHidden(true)
    }
}
