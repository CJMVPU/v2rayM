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
        VStack(alignment: .leading, spacing: 10) {
            Toggle("开机启动", isOn: Binding(get: { registered }, set: setEnabled))
                .toggleStyle(.switch)
                .disabled(updating || !bundled)
            Text("登录 macOS 后自动启动 v2rayM。")
                .font(AppFont.caption).foregroundStyle(.secondary)
            if status == .requiresApproval {
                HStack {
                    Text("等待系统批准登录项").font(AppFont.caption).foregroundStyle(.secondary)
                    Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
            } else if !bundled {
                Text("请运行打包后的 v2rayM.app 来设置开机启动。")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }
        }
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
