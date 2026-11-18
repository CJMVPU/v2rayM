import SwiftUI

/// Shared presentation only; settings persistence stays in AppModel's command path.
struct SettingsCard<Content: View>: View {
    let title: String
    var symbol: ControlAsset? = nil
    var subtitle: String = ""
    var fillHeight: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let symbol { RealityLabel(title: title, asset: symbol, color: DashboardTheme.accent) }
                    else { Text(title) }
                }.font(AppFont.body).foregroundStyle(DashboardTheme.accent)
                if !subtitle.isEmpty { Text(subtitle).font(AppFont.caption).foregroundStyle(DashboardTheme.muted) }
            }
            content
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
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
