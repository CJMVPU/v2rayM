import SwiftUI
import V2rayMKit

struct HomeDashboard: View {
    @EnvironmentObject var model: AppModel
    let showNodes: () -> Void
    let showSettings: () -> Void
    let showLogs: () -> Void
    private var node: Profile? {
        let id = model.status?.coreRunning == true ? model.status?.runningProfileId : model.status?.currentProfileId
        return model.profiles.first { $0.id == id }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = DashboardStatus.resolve(ready: model.ready, updating: model.moduleUpdateActive,
                busy: model.busy, recovery: model.proxyNeedsRecovery, state: model.status,
                tunRunning: model.tun?.isRunning == true, systemProxy: model.systemProxyEnabled,
                lastRefresh: model.lastStatusRefresh, now: context.date)
            let color: Color = state.active ? .green : [.faulted, .stale, .updating, .changing].contains(state) ? .orange : .secondary
            VStack(spacing: 10) {
                HStack(spacing: 18) {
                    Image(systemName: state.active ? "checkmark.shield.fill" : state == .faulted ? "exclamationmark.shield" : "shield.slash")
                        .font(.system(size: 46, weight: .light)).foregroundStyle(color)
                        .frame(width: 76, height: 76).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.connecting ? "正在连接本地服务" : state.title).font(AppFont.title)
                        HStack(spacing: 7) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(state.active ? (state == .tun ? "原生 TUN · 系统流量接管" : "系统代理 · 遵循系统代理的应用") : subtitle(state))
                                .font(AppFont.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if !model.ready {
                        Button("重新连接") { Task { await model.connect() } }.disabled(model.connecting)
                    }
                    VStack(alignment: .trailing, spacing: 7) {
                        Text("本次运行").font(AppFont.caption).foregroundStyle(.secondary)
                        Text(model.status?.coreRunning == true && state != .offline ? DashboardStatus.duration(since: model.status?.coreStartedAt, now: context.date) : "—")
                            .monospacedDigit().font(AppFont.title)
                    }
                }.padding(12).panel()

                HStack(spacing: 10) {
                    pathItem("desktopcomputer", "Mac 应用", state.active ? "流量入口" : "等待开启", color: color)
                    Image(systemName: "chevron.right").foregroundStyle(color.opacity(0.6))
                    pathItem("cpu", model.tun?.isRunning == true ? "Xray 原生 TUN" : "Xray", model.tun?.isRunning == true ? "直接接入虚拟网卡" : "本地代理监听", color: color)
                    Image(systemName: "chevron.right").foregroundStyle(color.opacity(0.6))
                    pathItem("server.rack", "节点服务器", node.map { $0.protocol.uppercased() + " · " + ($0.network.isEmpty ? "TCP" : $0.network) } ?? "尚未选择节点", color: color)
                }.padding(10).panel()

                let rates = (state.active || state == .local) ? model.status?.traffic?.rates(at: context.date) : nil
                let sampling = DashboardStatus.trafficDescription(state: state, enabled: model.status?.trafficEnabled, hasSample: rates != nil)
                HStack(spacing: 10) {
                    metric("代理上行", icon: "arrow.up.right", value: DashboardStatus.rate(rates?[0]), color: .blue)
                    metric("代理下行", icon: "arrow.down.left", value: DashboardStatus.rate(rates?[1]), color: .teal)
                    metric("直连上行", icon: "arrow.up.right", value: DashboardStatus.rate(rates?[2]), color: .secondary)
                    metric("直连下行", icon: "arrow.down.left", value: DashboardStatus.rate(rates?[3]), color: .secondary)
                }.help(model.status?.trafficEnabled == true ? "流量来自 Xray 实际采样；无新数据时显示 —。" : "实时流量未采集，可在参数设置中开启。")
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Label("节点信息", systemImage: "server.rack")
                            Text("\(model.profiles.count)").font(AppFont.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            dashboardLink("节点", action: showNodes)
                        }
                        Divider()
                        VStack(spacing: 4) {
                            informationRow("当前节点", value: node?.remarks ?? model.status?.runningProfileName ?? model.status?.currentProfileName ?? "尚未选择")
                            informationRow("服务器", value: node.map { "\($0.address):\($0.port)" } ?? "—")
                            informationRow("节点协议", value: node?.protocol.uppercased() ?? "—")
                            informationRow("传输安全", value: node.map { ($0.network.isEmpty ? "TCP" : $0.network) + " / " + (($0.streamSecurity ?? "").isEmpty ? "无 TLS" : $0.streamSecurity!.uppercased()) } ?? "—")
                            informationRow("最近延迟", value: node.flatMap { $0.delay > 0 ? "\($0.delay) ms" : nil } ?? "未测速")
                            informationRow("累计上传", value: model.status?.statisticsEnabled == true ? DashboardStatus.amount(node?.totalUp) : "未开启累计统计")
                            informationRow("累计下载", value: model.status?.statisticsEnabled == true ? DashboardStatus.amount(node?.totalDown) : "未开启累计统计")
                        }
                    }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).panel()
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Label("运行环境", systemImage: "cpu")
                            Spacer(minLength: 4)
                            dashboardLink("设置", action: showSettings)
                            dashboardLink("日志", action: showLogs)
                        }
                        Divider()
                        VStack(spacing: 4) {
                            informationRow("路由方案", value: model.routes.first(where: \.isActive)?.remarks ?? "—")
                            informationRow("Xray 内核", value: model.status.map { $0.xrayAvailable ? ($0.installedXrayVersion ?? "版本未读取") : "未安装" } ?? "待检查")
                            informationRow("代理模式", value: modeDescription(state))
                            informationRow("TUN 服务", value: model.tun.map { $0.helperAvailable ? "已就绪" : "未就绪" } ?? "待检查")
                            informationRow("代理端口", value: (model.status?.coreRunning == true ? model.status?.runningProxyPort : model.status?.configuredProxyPort).map(String.init) ?? "—")
                            informationRow("流量采集", value: sampling)
                            informationRow("累计统计", value: model.status.map { $0.statisticsEnabled == true ? "已开启 · 按节点保存" : "未开启" } ?? "待检查")
                        }
                    }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).panel()
                }
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
    private func modeDescription(_ state: DashboardStatus) -> String {
        switch state {
        case .tun: return "Xray 原生 TUN"
        case .system: return "系统代理"
        case .local: return "仅本地监听"
        case .stopped: return "已关闭"
        default: return state.title
        }
    }
    private func subtitle(_ state: DashboardStatus) -> String {
        switch state {
        case .offline: return "等待本地服务恢复"
        case .faulted: return model.proxyNeedsRecovery ? "系统代理需要恢复，请使用标题栏恢复按钮" : "内核运行异常，查看日志了解原因"
        case .updating: return "下载与校验中，切换内核时会短暂重连"
        case .changing: return "操作完成后自动刷新状态"
        case .stale: return "最近状态暂未刷新，不代表已连接"
        case .local: return "尚未开启系统代理或 TUN"
        default: return "使用标题栏开关选择系统代理或 TUN"
        }
    }
    private func pathItem(_ icon: String, _ title: String, _ subtitle: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(color)
            Text(title).lineLimit(1)
            Text(subtitle).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }
    private func metric(_ title: String, icon: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(AppFont.caption).foregroundStyle(color)
            Text(value).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).panel()
    }
    private func dashboardLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
            }.font(AppFont.caption)
        }.buttonStyle(HoverButtonStyle(plain: true)).foregroundStyle(Color.accentColor)
    }
    private func informationRow(_ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(AppFont.caption).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value).lineLimit(1).help(value).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 20, maxHeight: .infinity)
    }

}
private extension View {
    func panel() -> some View {
        background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}
