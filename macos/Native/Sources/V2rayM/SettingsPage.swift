import SwiftUI
import AppKit
import V2rayMKit

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @Binding var navigationLocked: Bool
    var homeRequest = 0
    var goHome: () -> Void = {}
    @State private var pane: SettingsPane?
    private var disabled: Bool { !model.ready || model.busy || model.moduleUpdateActive }
    var body: some View {
        if let pane {
            SettingsEditor(pane: pane, homeRequest: homeRequest, goHome: goHome, close: { self.pane = nil; navigationLocked = false }).environmentObject(model)
        } else { overview }
    }
    private var overview: some View {
        GeometryReader { viewport in
            ScrollView(showsIndicators: false) {
                overviewCards
                    .frame(minHeight: max(0, viewport.size.height - 2 * PageLayout.gap), alignment: .top)
                    .padding(.horizontal, PageLayout.gap)
                    .background(SettingsWheelScroll())
            }.scrollIndicators(.never).realityClipped().padding(.vertical, PageLayout.gap)
        }
    }

    private var overviewCards: some View {
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
                                    model.run { try await $0.activateRoute(route.id) }
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
            }
            SettingsCard(title: "网络配置", symbol: .topology) {
                AdvancedSettingsPanel(select: { pane = $0; navigationLocked = true }).environmentObject(model)
            }
            ModuleUpdatePanel().environmentObject(model)
            HStack(alignment: .top, spacing: PageLayout.gap) {
                SettingsCard(title: "TUN 后台服务", symbol: .shieldCheck, fillHeight: true, headerAction: {
                    Button(model.tun?.helperAvailable == true || model.tun?.helperCode == "helper_protocol_mismatch" ? "检查与修复" : "安装并授权") { model.authorizeTun() }
                        .disabled(disabled || model.tun?.isRunning == true)
                    Button("后台服务设置") { model.openTunApproval() }.disabled(disabled)
                }) {
                    LabeledContent("运行状态", value: model.tun?.isRunning == true ? "运行中" : "已关闭")
                        .frame(minHeight: 20, alignment: .leading)
                    LabeledContent("后台服务", value: model.tun?.helperDescription ?? "正在检查")
                        .frame(minHeight: 20, alignment: .topLeading)
                }
                SettingsCard(title: "日志与数据", symbol: .folder, fillHeight: true, headerAction: {
                    Button("备份与恢复") { pane = .backup; navigationLocked = true }.disabled(disabled)
                    Button("在访达中打开") { NSWorkspace.shared.open(model.dataDirectory) }
                }) {
                    Text("保留最近 10,000 行日志，切换模式时保留历史。")
                        .foregroundStyle(DashboardTheme.muted)
                        .frame(minHeight: 20, alignment: .leading)
                    Text(model.dataDirectory.path).foregroundStyle(DashboardTheme.muted)
                        .lineLimit(2).textSelection(.enabled)
                        .frame(minHeight: 20, alignment: .topLeading)
                }
            }.font(AppFont.body)
        }
    }
}
