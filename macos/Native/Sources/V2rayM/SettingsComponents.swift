import SwiftUI

/// Shared presentation only; settings persistence stays in AppModel's command path.
struct SettingsCard<Content: View, HeaderAction: View>: View {
    let title: String
    let symbol: ControlAsset?
    let subtitle: String
    let fillHeight: Bool
    let headerAction: HeaderAction
    let content: Content

    init(title: String, symbol: ControlAsset? = nil, subtitle: String = "", fillHeight: Bool = false,
         @ViewBuilder headerAction: () -> HeaderAction = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.fillHeight = fillHeight
        self.headerAction = headerAction()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Group {
                        if let symbol { RealityLabel(title: title, asset: symbol, color: DashboardTheme.accent) }
                        else { Text(title) }
                    }.font(AppFont.body).foregroundStyle(DashboardTheme.accent).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    headerAction
                }
                if !subtitle.isEmpty { Text(subtitle).font(AppFont.caption).foregroundStyle(DashboardTheme.muted) }
            }
            content
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .realityCard()
    }
}

struct SettingsFormSection<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        SettingsCard(title: title, subtitle: subtitle) { content }
    }
}

struct SettingsFieldRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 180, alignment: .leading)
            content
        }.frame(minHeight: 26)
    }
}

/// A busy indicator must not take width from adjacent status text when it starts.
struct InlineActivityIndicator: View {
    let active: Bool
    var body: some View {
        Color.clear.frame(width: 16, height: 16).overlay {
            if active { RealityBusyIndicator() }
        }.accessibilityHidden(!active)
    }
}
