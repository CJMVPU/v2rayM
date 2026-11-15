import SwiftUI

/// Shared presentation only; settings persistence stays in AppModel's command path.
struct SettingsCard<Content: View>: View {
    let title: String
    var symbol: String? = nil
    var subtitle: String = ""
    var fillHeight: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let symbol { Label(title, systemImage: symbol) }
                    else { Text(title) }
                }.font(AppFont.body).foregroundStyle(DashboardTheme.cyan)
                if !subtitle.isEmpty { Text(subtitle).font(AppFont.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(DashboardTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DashboardTheme.line.opacity(0.55)))
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
