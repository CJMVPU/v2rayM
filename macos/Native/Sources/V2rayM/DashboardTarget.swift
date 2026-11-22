import SwiftUI

enum PageLayout {
    static let gap: CGFloat = 8
    static let space = "dashboard-navigation"
}

private struct OpenDashboardPage: EnvironmentKey {
    static let defaultValue: (Page, CGPoint) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var openDashboardPage: (Page, CGPoint) -> Void {
        get { self[OpenDashboardPage.self] }
        set { self[OpenDashboardPage.self] = newValue }
    }
}

/// Invisible native target over existing dashboard artwork. Keyboard and
/// accessibility activations originate at the center of the same artwork.
struct DashboardTarget: View {
    let page: Page
    var circular = false
    @Environment(\.openDashboardPage) private var open
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        GeometryReader { geometry in
            NavigationButton(label: page.rawValue, enabled: enabled, circular: circular) { location in
                let frame = geometry.frame(in: .named(PageLayout.space))
                open(page, CGPoint(x: frame.minX + location.x * frame.width,
                                   y: frame.minY + location.y * frame.height))
            }
        }
    }
}
