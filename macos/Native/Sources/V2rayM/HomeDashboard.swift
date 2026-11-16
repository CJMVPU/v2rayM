import SwiftUI
import V2rayMKit

enum DashboardTheme {
    static let background = Color(nsColor: .controlBackgroundColor)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let line = Color(red: 0.16, green: 0.26, blue: 0.36)
    static let muted = Color(red: 0.57, green: 0.65, blue: 0.77)
    static let cyan = Color(red: 0.02, green: 0.83, blue: 0.96)
    static let directUpload = Color(red: 0.22, green: 0.79, blue: 0.48)
    static let directDownload = Color(red: 1.0, green: 0.65, blue: 0.24)
    static let purple = Color(red: 0.72, green: 0.35, blue: 0.98)
}

struct HomeDashboard: View {
    @EnvironmentObject var model: AppModel
    var body: some View { DashboardContent(monitor: model.dashboard, telemetry: model.telemetry).environmentObject(model) }
}

private struct DashboardContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var monitor: GlobeMonitor
    @ObservedObject var telemetry: RuntimeTelemetry
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
                VStack(spacing: 8) {
                    trafficMetric("代理上传", icon: "arrow.up.right", value: DashboardStatus.rate(rates?[0]), color: DashboardTheme.cyan)
                    trafficMetric("直连上传", icon: "arrow.up.right", value: DashboardStatus.rate(rates?[2]), color: DashboardTheme.directUpload)
                }
                Rectangle().fill(DashboardTheme.line).frame(width: 0.5, height: 42)
                VStack(spacing: 8) {
                    trafficMetric("代理下载", icon: "arrow.down.left", value: DashboardStatus.rate(rates?[1]), color: DashboardTheme.purple)
                    trafficMetric("直连下载", icon: "arrow.down.left", value: DashboardStatus.rate(rates?[3]), color: DashboardTheme.directDownload)
                }
            }
            rule
            Text("节点累计").font(AppFont.size(13))
            HStack(spacing: 10) {
                trafficMetric("代理累计上传", icon: "arrow.up.right", value: DashboardStatus.amount(model.status?.statisticsEnabled == true ? node?.totalUp : nil),
                              color: DashboardTheme.cyan)
                Rectangle().fill(DashboardTheme.line).frame(width: 0.5, height: 22)
                trafficMetric("代理累计下载", icon: "arrow.down.left", value: DashboardStatus.amount(model.status?.statisticsEnabled == true ? node?.totalDown : nil),
                              color: DashboardTheme.purple)
            }
        }.padding(12).dashboardPanel()
            .help(DashboardStatus.trafficDescription(state: state, enabled: model.status?.trafficEnabled, hasSample: rates != nil)
                + "；第一行青／紫为代理上传／下载，第二行绿／橙为直连上传／下载。直连仅包含经过 Xray 的流量；节点累计仅统计当前节点的代理流量。")
    }
    private func trafficMetric(_ title: String, icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13))
            Text(value).font(AppFont.size(18))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: value)
        }.foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(title + " " + value)
            .help(title + "：" + value)
    }
    private var recentCard: some View {
        RecentConnectionsCard(connections: monitor.connections, coreRunning: model.status?.coreRunning == true)
    }
}

struct RecentConnectionsCard: View {
    let connections: [GlobeConnection]
    let coreRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                if connections.isEmpty {
                    Text(coreRunning ? "等待新的连接记录" : "开启代理后显示连接")
                        .font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(connections.prefix(6))) { connection in
                            recentConnectionRow(connection, height: max(0, (geometry.size.height - 20) / 6))
                        }
                    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: Array(connections.prefix(6).map(\.id)))
                }
            }.clipped()
        }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            .frame(maxHeight: .infinity).dashboardPanel()
    }

    private func recentConnectionRow(_ connection: GlobeConnection, height: CGFloat) -> some View {
        let color: Color = connection.isProxy ? DashboardTheme.cyan : connection.route == "direct" ? .green : .orange
        let location: String = connection.place.map { " · " + $0.displayCity + "（IP/DNS 估计）" } ?? " · 位置未知"
        let tooltip: String = connection.host + ":\(connection.port) · " + connection.routeTitle + location
        return HStack(spacing: 8) {
            Text(connection.host).font(AppFont.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(connection.routeTitle).font(AppFont.caption).foregroundStyle(DashboardTheme.muted).fixedSize()
        }.padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: height)
            .background(color.opacity(colorScheme == .dark ? 0.13 : 0.10), in: RoundedRectangle(cornerRadius: 5))
            .help(tooltip)
            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                   removal: .opacity))
    }
}

private extension View {
    func dashboardPanel() -> some View {
        background(LinearGradient(colors: [DashboardTheme.panel, DashboardTheme.panel.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DashboardTheme.line.opacity(0.55), lineWidth: 0.6))
    }
}
