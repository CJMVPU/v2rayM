import SwiftUI
import AppKit
import V2rayMKit

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @Binding var navigationLocked: Bool
    @State private var pane: SettingsPane?
    private var disabled: Bool { !model.ready || model.busy || model.moduleUpdateActive }
    var body: some View {
        if let pane {
            SettingsEditor(pane: pane, close: { self.pane = nil; navigationLocked = false }).environmentObject(model)
        } else { overview }
    }
    private var overview: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageLayout.gap) {
                SettingsCard(title: "通用与代理", symbol: .sliders) {
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
                                        RealityLabel(title: settingsRouteLabel(route.remarks), asset: route.isActive ? .current : .circle, color: route.isActive ? DashboardTheme.accent : DashboardTheme.muted)
                                            .lineLimit(1).fixedSize()
                                            .foregroundStyle(route.isActive ? DashboardTheme.accent : DashboardTheme.text)
                                            .padding(.vertical, 3)
                                    }.disabled(disabled)
                                        .accessibilityAddTraits(route.isActive ? [.isSelected] : [])
                                }
                            }.background(SettingsWheelScroll())
                        }
                    }
                    HStack(spacing: 18) {
                        RealityLabel(title: "代理端口 " + (model.status?.configuredProxyPort.map(String.init) ?? "—"), asset: .network, color: DashboardTheme.muted)
                        RealityLabel(title: model.status?.xrayAvailable == true ? "Xray 已安装" : "Xray 未安装", asset: .package, color: DashboardTheme.muted)
                    }.font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                }
                SettingsCard(title: "网络配置", symbol: .topology) {
                    AdvancedSettingsPanel(select: { pane = $0; navigationLocked = true }).environmentObject(model)
                }
                SettingsCard(title: "模块更新", symbol: .sync) {
                    ModuleUpdatePanel().environmentObject(model)
                }
                HStack(alignment: .top, spacing: PageLayout.gap) {
                    SettingsCard(title: "TUN 后台服务", symbol: .shieldCheck, fillHeight: true) {
                        LabeledContent("运行状态", value: model.tun?.isRunning == true ? "运行中" : "已关闭")
                        LabeledContent("后台服务", value: model.tun?.helperDescription ?? "正在检查")
                        HStack {
                            Button("安装并授权") { model.authorizeTun() }
                                .disabled(disabled || model.tun?.helperAvailable == true)
                            Button("后台服务设置") { model.openTunApproval() }.disabled(disabled)
                        }
                        Text("开启前请先暂停其他软件的 TUN 或 VPN。")
                            .font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                    }
                    SettingsCard(title: "日志与数据", symbol: .folder, fillHeight: true) {
                        Text("保留最近 10,000 行日志，切换模式时保留历史。")
                            .font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                        Text(model.dataDirectory.path).font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                            .lineLimit(2).textSelection(.enabled)
                        Button("在访达中打开") { NSWorkspace.shared.open(model.dataDirectory) }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, PageLayout.gap).background(SettingsWheelScroll())
        }.scrollIndicators(.never).realityClipped().padding(.vertical, PageLayout.gap)
    }
}
