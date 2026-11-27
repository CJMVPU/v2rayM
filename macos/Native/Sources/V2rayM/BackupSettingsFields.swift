import AppKit
import SwiftUI
import UniformTypeIdentifiers
import V2rayMKit

struct BackupSettingsFields: View {
    @EnvironmentObject var model: AppModel
    @Binding var settings: SettingsValue
    @Binding var dirty: Bool
    let perform: (String, @escaping () async throws -> Void) -> Void
    @State private var restoring = false
    @State private var localRestoreFile: URL?
    private var hasCredentials: Bool {
        !settings["url"].text.isEmpty && !settings["userName"].text.isEmpty && settings["hasPassword"].flag
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { settings[key].text }, set: { settings[key] = .string($0); dirty = true })
    }

    var body: some View {
        SettingsCard(title: "本地 ZIP", symbol: .folder) {
            HStack {
                Button("导出备份…") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.zip]
                    panel.nameFieldStringValue = "v2rayM-backup.zip"
                    if panel.runModal() == .OK, let url = panel.url {
                        perform("备份已导出") { try await model.exportBackup(to: url) }
                    }
                }
                Button("从文件恢复…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.zip]
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { localRestoreFile = url; restoring = true }
                }
            }.disabled(dirty)
        }
        SettingsCard(title: "WebDAV", symbol: .network) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("服务器"); TextField("https://", text: binding("url")) }
                GridRow { Text("目录"); TextField("v2rayN_backup", text: binding("dirName")) }
                GridRow { Text("用户名"); TextField("", text: binding("userName")) }
                GridRow { Text("密码"); SecureField(settings["hasPassword"].flag ? "已保存" : "", text: binding("password")) }
            }
            HStack {
                Button("测试连接") { perform("WebDAV 读写验证通过") { try await model.settingsWrite { try await $0.checkWebDAV() } } }
                Button("上传备份") { perform("备份已上传") { try await model.settingsWrite { try await $0.uploadBackup() } } }
                Button("从 WebDAV 恢复…") { localRestoreFile = nil; restoring = true }
            }.disabled(dirty || !hasCredentials)
        }
        .alert("恢复备份中的设置和节点？", isPresented: $restoring) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                let file = localRestoreFile
                perform("备份已恢复") {
                    if let file { try await model.restoreBackup(from: file) }
                    else { try await model.settingsWrite { try await $0.restoreWebDAVBackup() } }
                    settings = try await model.settingsRead { try await $0.settingsSection(.webDAV) }
                }
            }
        } message: { Text("应用会先保存当前数据到 guiBackups，并在恢复后重新连接原先运行的代理。") }
    }
}
