import SwiftUI

enum PageLayout {
    static let gap: CGFloat = 8
}

private struct OpenDashboardPage: EnvironmentKey {
    static let defaultValue: (Page) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var dashboardNavigationLocked = false
    var openDashboardPage: (Page) -> Void {
        get { self[OpenDashboardPage.self] }
        set { self[OpenDashboardPage.self] = newValue }
    }
}

/// Invisible native target over existing dashboard artwork. Keyboard and
/// accessibility activations originate at the center of the same artwork.
struct DashboardTarget: View {
    let page: Page
    var circular = false
    var hover: Binding<Bool>? = nil
    @Environment(\.openDashboardPage) private var open
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dashboardNavigationLocked) private var locked
    var body: some View {
        NavigationButton(label: page.rawValue, enabled: enabled && !locked, circular: circular, hoverChanged: hover.map { binding in
            { value in
                if binding.wrappedValue != value { binding.wrappedValue = value }
            }
        }) { _ in open(page) }
            .onDisappear { hover?.wrappedValue = false }
            .onChange(of: enabled && !locked) { _, active in if !active { hover?.wrappedValue = false } }
    }
}
