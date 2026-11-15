import SwiftUI
import AppKit
import V2rayMKit

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @Binding var navigationLocked: Bool
    @State private var pane: SettingsPane?
    private var versionLabel: String {
        guard Bundle.main.bundleIdentifier == "io.github.CJMVPU.v2rayM",
              let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return "开发构建" }
        return "v" + version
    }
    private var disabled: Bool { !model.ready || model.busy || model.moduleUpdateActive }
    var body: some View {
        if let pane {
            SettingsEditor(pane: pane, close: { self.pane = nil; navigationLocked = false }).environmentObject(model)
        } else { overview }
    }
    private var overview: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("设置").font(AppFont.title)
                    Text("连接偏好、网络规则与维护").font(AppFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(versionLabel)
                        .font(AppFont.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 2)
                SettingsCard(title: "通用与代理", symbol: "slider.horizontal.3") {
                    LoginItemSettings().environmentObject(model)
                    Divider().opacity(0.5)
                    HStack(spacing: 12) {
                        Text("路由方案").frame(width: 80, alignment: .leading)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.routes) { route in
                                    Button {
                                        guard !route.isActive else { return }
                                        model.run { try await $0.perform("/api/settings/routing-profiles/\(route.id)/activate") }
                                    } label: {
                                        Label(route.remarks, systemImage: route.isActive ? "checkmark.circle.fill" : "circle")
                                            .lineLimit(1).fixedSize()
                                            .foregroundStyle(route.isActive ? DashboardTheme.cyan : Color.primary)
                                            .padding(.vertical, 3)
                                    }.disabled(disabled)
                                        .accessibilityAddTraits(route.isActive ? [.isSelected] : [])
                                }
                            }
                        }
                    }
                    HStack(spacing: 18) {
                        Label("代理端口 " + (model.status?.configuredProxyPort.map(String.init) ?? "—"), systemImage: "network")
                        Label(model.status?.xrayAvailable == true ? "Xray 已安装" : "Xray 未安装", systemImage: "shippingbox")
                    }.font(AppFont.caption).foregroundStyle(.secondary)
                }
                SettingsCard(title: "网络配置", symbol: "point.3.connected.trianglepath.dotted") {
                    AdvancedSettingsPanel(select: { pane = $0; navigationLocked = true }).environmentObject(model)
                }
                SettingsCard(title: "模块更新", symbol: "arrow.triangle.2.circlepath") {
                    ModuleUpdatePanel().environmentObject(model)
                }
                HStack(alignment: .top, spacing: 12) {
                    SettingsCard(title: "TUN 后台服务", symbol: "checkmark.shield") {
                        LabeledContent("运行状态", value: model.tun?.isRunning == true ? "运行中" : "已关闭")
                        LabeledContent("后台服务", value: model.tun?.helperDescription ?? "正在检查")
                        HStack {
                            if model.tun?.helperAvailable != true {
                                Button("安装并授权") { model.authorizeTun() }.disabled(disabled)
                            }
                            Button("后台服务设置") { model.openTunApproval() }.disabled(disabled)
                        }
                        Text("开启前请先暂停其他软件的 TUN 或 VPN。")
                            .font(AppFont.caption).foregroundStyle(.secondary)
                    }
                    SettingsCard(title: "日志与数据", symbol: "folder") {
                        Text("保留最近 10,000 行日志，切换模式时保留历史。")
                            .font(AppFont.caption).foregroundStyle(.secondary)
                        Text(model.dataDirectory.path).font(AppFont.caption).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                        Button("在访达中打开") { NSWorkspace.shared.open(model.dataDirectory) }
                    }
                }
            }.padding(16)
        }.scrollIndicators(.never).background(DashboardTheme.background)
    }
}
