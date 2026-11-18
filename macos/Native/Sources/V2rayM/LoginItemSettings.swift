import SwiftUI
import ServiceManagement

/// The OS owns the preference; always read its status instead of keeping a second copy.
struct LoginItemSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = SMAppService.mainApp.status
    @State private var updating = false

    private var registered: Bool { status == .enabled || status == .requiresApproval }
    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        LoginItemStatusRow(registered: Binding(get: { registered }, set: setEnabled),
            requiresApproval: status == .requiresApproval, bundled: bundled, updating: updating,
            openSettings: { SMAppService.openSystemSettingsLoginItems() })
        .onAppear { status = SMAppService.mainApp.status }
        .onChange(of: scenePhase) {
            if scenePhase == .active { status = SMAppService.mainApp.status }
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !updating, bundled else { return }
        updating = true
        Task { @MainActor in
            defer {
                status = SMAppService.mainApp.status
                updating = false
            }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                model.error = "无法修改开机启动：" + error.localizedDescription
            }
        }
    }
}

/// Approval and its action share the toggle row.
struct LoginItemStatusRow: View {
    @Binding var registered: Bool
    let requiresApproval: Bool
    let bundled: Bool
    let updating: Bool
    let openSettings: () -> Void
    var body: some View {
        HStack {
            Text("开机启动")
            if requiresApproval {
                Text("等待系统批准登录项")
                    .font(AppFont.caption).foregroundStyle(DashboardTheme.muted).lineLimit(1)
            }
            Spacer()
            Button("打开登录项设置", action: openSettings)
                .environment(\.realityContentVisible, requiresApproval)
                .disabled(!requiresApproval).opacity(requiresApproval ? 1 : 0)
                .accessibilityHidden(!requiresApproval)
            Toggle("开机启动", isOn: $registered)
                .labelsHidden().toggleStyle(RealityToggleStyle(showsLabel: false)).disabled(updating || !bundled)
                .help(bundled ? "开机启动" : "请运行打包后的 v2rayM.app 来设置开机启动。")
        }
    }
}
