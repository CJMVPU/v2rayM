import SwiftUI
import V2rayMKit

enum DashboardTheme {
    static let background = Color(nsColor: .controlBackgroundColor)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let line = Color(red: 0.16, green: 0.26, blue: 0.36)
    static let muted = Color(red: 0.57, green: 0.65, blue: 0.77)
    static let cyan = Color(red: 0.02, green: 0.83, blue: 0.96)
    static let purple = Color(red: 0.72, green: 0.35, blue: 0.98)
}

struct HomeDashboard: View {
    @EnvironmentObject var model: AppModel
    var body: some View { DashboardContent(monitor: model.dashboard).environmentObject(model) }
}

private struct DashboardContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var monitor: GlobeMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alpn = ""
    private var node: Profile? {
        let id = model.status?.coreRunning == true ? model.status?.runningProfileId : model.status?.currentProfileId
        return model.profiles.first { $0.id == id }
    }
    private var nodeName: String {
        let name = node?.remarks ?? model.status?.runningProfileName ?? model.status?.currentProfileName ?? "尚未选择"
        return name.isEmpty ? "未命名节点" : name
    }
    private var protocols: String {
        guard let node else { return "等待选择节点" }
        var values = [node.protocol.uppercased(), node.network.isEmpty ? "TCP" : node.network.uppercased()]
        if let tls = node.streamSecurity, !tls.isEmpty { values.append(tls.uppercased()) }
        let labels = alpn.split(whereSeparator: { $0 == "," || $0 == " " }).map { value in
            value == "h2" ? "HTTP/2" : value == "h3" ? "HTTP/3" : String(value).uppercased()
        }
        values.append(contentsOf: labels)
        return values.joined(separator: " / ")
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = model.displayStatus(at: context.date)
            let live = state.active || state == .local
            let rates = live && model.status?.trafficEnabled == true ? model.status?.traffic?.rates(at: context.date) : nil
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ConnectionDashboard(state: state, city: monitor.nodePlace?.displayCity ?? "位置未知",
                            nodeName: nodeName, node: node, startedAt: model.status?.coreStartedAt,
                            coreRunning: model.status?.coreRunning == true, rates: rates,
                            trend: model.trafficTrend, trafficEnabled: model.status?.trafficEnabled,
                            now: context.date, connecting: model.connecting,
                            reconnect: { Task { await model.connect() } })
                            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
                        VStack(spacing: 12) {
                            nodeCard(state: state, now: context.date)
                            trafficCard(rates: rates, state: state)
                            recentCard
                        }.frame(width: geometry.size.width * 0.325, height: max(0, geometry.size.height - 24))
                            .padding(.trailing, 12).padding(.vertical, 12)
                    }
                }

            }
        }.background(DashboardTheme.background)
            .task(id: node?.id) {
                alpn = ""
                guard let node else { return }
                do {
                    let value = try await model.settingsRead("/api/profiles/\(node.id)")
                    guard !Task.isCancelled else { return }
                    alpn = value["alpn"].text
                } catch { /* Missing detail must not invent a negotiated protocol. */ }
            }
    }
    private func nodeCard(state: DashboardStatus, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                statusIcon("shield.lefthalf.filled", title: "后台服务", enabled: model.ready && model.tun?.helperAvailable == true)
                Rectangle().fill(DashboardTheme.line.opacity(0.5)).frame(width: 0.5, height: 32)
                statusIcon("arrow.left.arrow.right", title: "系统代理", enabled: state == .system)
                Rectangle().fill(DashboardTheme.line.opacity(0.5)).frame(width: 0.5, height: 32)
                statusIcon("personalhotspot", title: "TUN", enabled: state == .tun)
            }.padding(.top, 2).padding(.bottom, 10)
            rule
            HStack {
                Text("连接时长").foregroundStyle(DashboardTheme.muted)
                Spacer()
                Text(model.status?.coreRunning == true ? DashboardStatus.duration(since: model.status?.coreStartedAt, now: now) : "—")
                    .font(AppFont.size(14)).monospacedDigit()
            }.padding(.vertical, 9)
            rule
            Text("当前节点").font(AppFont.caption).foregroundStyle(DashboardTheme.muted).padding(.top, 11)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(monitor.nodePlace?.displayCity ?? "位置未知").font(AppFont.size(21)).lineLimit(1).minimumScaleFactor(0.75)
                Text("·").foregroundStyle(DashboardTheme.muted)
                Text(nodeName).font(AppFont.size(14)).foregroundStyle(DashboardTheme.muted)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).help(nodeName)
            }.padding(.top, 6).padding(.bottom, 8)
            Text(protocols).font(AppFont.size(10.5)).foregroundStyle(DashboardTheme.muted)
                .lineLimit(1).minimumScaleFactor(0.8).help("节点配置：" + protocols + "。ALPN 是配置值，不代表已协商的协议。")
            Text("Xray " + (model.status?.installedXrayVersion ?? "版本待读取"))
                .font(AppFont.size(10))
                .foregroundStyle(DashboardTheme.muted.opacity(0.75)).lineLimit(1).padding(.top, 7)
        }.padding(12).dashboardPanel()
    }
    private func statusIcon(_ icon: String, title: String, enabled: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 21, weight: .medium))
                .frame(height: 28)
                .shadow(color: enabled ? .green.opacity(0.3) : .clear, radius: 6)
            Text(title).font(AppFont.caption).frame(height: 16)
        }.foregroundStyle(enabled ? Color.green : DashboardTheme.muted)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore).accessibilityLabel(title + (enabled ? "已就绪" : "未开启"))
    }
    private var rule: some View { Rectangle().fill(DashboardTheme.line.opacity(0.7)).frame(height: 0.5) }
    private func trafficCard(rates: [Double]?, state: DashboardStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时流量").font(AppFont.size(13))
            HStack(spacing: 10) {
                trafficColumn("上传", icon: "arrow.up.right", rate: rates?[0], color: DashboardTheme.cyan)
                Rectangle().fill(DashboardTheme.line).frame(width: 0.5, height: 36)
                trafficColumn("下载", icon: "arrow.down.left", rate: rates?[1], color: DashboardTheme.purple)
            }
            rule
            Text("节点累计").font(AppFont.size(13))
            HStack(spacing: 10) {
                trafficMetric("上传", icon: "arrow.up.right", value: DashboardStatus.amount(model.status?.statisticsEnabled == true ? node?.totalUp : nil),
                              color: DashboardTheme.cyan)
                Rectangle().fill(DashboardTheme.line).frame(width: 0.5, height: 36)
                trafficMetric("下载", icon: "arrow.down.left", value: DashboardStatus.amount(model.status?.statisticsEnabled == true ? node?.totalDown : nil),
                              color: DashboardTheme.purple)
            }
        }.padding(12).dashboardPanel()
            .help(DashboardStatus.trafficDescription(state: state, enabled: model.status?.trafficEnabled, hasSample: rates != nil)
                + "；仅统计代理流量。累计值为当前节点历史总量。")
    }
    private func trafficColumn(_ title: String, icon: String, rate: Double?, color: Color) -> some View {
        trafficMetric(title, icon: icon, value: DashboardStatus.rate(rate), color: color)
    }
    private func trafficMetric(_ title: String, icon: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(AppFont.size(13))
            Text(value).font(AppFont.size(22))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: value)
        }.foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("近期连接").font(AppFont.size(13)).padding(.bottom, 5)
            GeometryReader { geometry in
                if monitor.connections.isEmpty {
                    Text(model.status?.coreRunning == true ? "等待新的连接记录" : "开启代理后显示连接")
                        .font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(monitor.connections.prefix(5))) { connection in
                            HStack(spacing: 8) {
                                Circle().fill(connection.isProxy ? DashboardTheme.cyan : connection.route == "direct" ? .green : .orange)
                                    .frame(width: 6, height: 6)
                                Text(connection.host).font(AppFont.caption).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(connection.routeTitle).font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                            }.frame(height: geometry.size.height / 5)
                                .overlay(alignment: .top) { rule }
                                .help(connection.host + ":\(connection.port) · " + connection.routeTitle
                                    + (connection.place.map { " · " + $0.displayCity + "（IP/DNS 估计）" } ?? " · 位置未知"))
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                       removal: .opacity))
                        }
                    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: Array(monitor.connections.prefix(5).map(\.id)))
                }
            }.clipped()
        }.padding(14).frame(maxHeight: .infinity).dashboardPanel()
    }

}

private extension View {
    func dashboardPanel() -> some View {
        background(LinearGradient(colors: [DashboardTheme.panel, DashboardTheme.panel.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DashboardTheme.line.opacity(0.55), lineWidth: 0.6))
    }
}
