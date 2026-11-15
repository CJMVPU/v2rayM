import SwiftUI

/// Shared presentation only; settings persistence stays in AppModel's command path.
struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(AppFont.body).foregroundStyle(DashboardTheme.cyan)
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardTheme.line.opacity(0.55)))
    }
}

struct SettingsFormSection<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppFont.body).foregroundStyle(DashboardTheme.cyan)
                if !subtitle.isEmpty { Text(subtitle).font(AppFont.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DashboardTheme.line.opacity(0.4)))
    }
}
