import SwiftUI
import V2rayMKit

struct HomeDashboard: View {
    @EnvironmentObject var model: AppModel
    var body: some View { DashboardSession(model: model) }
}

private struct DashboardSession: View {
    @Environment(\.dashboardVisibilityOverride) private var visibilityOverride
    @Environment(\.accessibilityReduceMotion) private var reduced
    @StateObject private var visibility = DashboardVisibilityCoordinator()
    @StateObject private var source: DashboardPresentationSource
    init(model: AppModel) { _source = StateObject(wrappedValue: DashboardPresentationSource(model: model)) }
    private var phase: DashboardPresentationPhase {
        visibilityOverride.map { $0 ? .live : .suspended } ?? visibility.phase
    }
    var body: some View {
        DashboardContent(data: source.snapshot, model: source.model).equatable()
            .environment(\.colorScheme, .dark)
            .environment(\.dashboardMotionEnabled, phase.rendersMotion)
            .environment(\.dashboardFlipsEnabled, phase.permitsFlips)
            .transaction {
                if !phase.rendersMotion { $0.disablesAnimations = true; $0.animation = nil }
            }
            .background {
                if visibilityOverride == nil {
                    DashboardVisibilityObserver(rendering: phase.rendersMotion) { state in
                        if !state.permitsRendering { source.setEnabled(false) }
                        visibility.update(state)
                    }
                }
            }
            .onAppear {
                let duration = visibility.catchUpDuration
                let reduceMotion = reduced, overridden = visibilityOverride != nil
                visibility.phaseChanged = { [weak source] phase in
                    guard !overridden else { return }
                    // Prepare the latest snapshot/replay before the render gate thaws.
                    withAnimation(phase == .catchingUp && !reduceMotion ? .easeInOut(duration: duration) : nil) {
                        source?.setEnabled(phase.acceptsData)
                    }
                }
                source.setEnabled(phase.acceptsData)
            }
            .onChange(of: phase, initial: true) { _, phase in
                withAnimation(phase == .catchingUp && !reduced ? .easeInOut(duration: visibility.catchUpDuration) : nil) {
                    source.setEnabled(phase.acceptsData)
                }
            }
            .onDisappear { visibility.phaseChanged = nil; source.setEnabled(false); visibility.stop() }
    }
}

private struct DashboardContent: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.data == rhs.data && lhs.model === rhs.model }
    let data: DashboardSnapshot
    let model: AppModel
    @State private var alpn = ""
    private var node: Profile? {
        let id = data.status?.coreRunning == true ? data.status?.runningProfileId : data.status?.currentProfileId
        return data.profiles.first { $0.id == id }
    }
    private var nodeName: String {
        let name = node?.remarks ?? data.status?.runningProfileName ?? data.status?.currentProfileName ?? "尚未选择"
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
        Group {
            let state = data.state
            let live = state.active || state == .local
            let rates = live && data.status?.trafficEnabled == true ? data.status?.traffic?.rates(at: data.now) : nil
            let cardsReady = rates != nil && !data.connections.isEmpty
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    // Reserve the same card slots through idle, loading and live telemetry.
                    let cardSpace = max(0, geometry.size.height - 24 - 2 * 12)
                    HStack(spacing: 0) {
                        ConnectionDashboard(state: state, city: data.nodePlace?.displayCity ?? "位置未知",
                            nodeName: nodeName, node: node, startedAt: data.status?.coreStartedAt,
                            coreRunning: data.status?.coreRunning == true, rates: rates,
                            trend: data.trend, catchUp: data.trendCatchUp, trafficEnabled: data.status?.trafficEnabled,
                            now: data.now, connecting: data.connecting,
                            reconnect: { Task { await model.connect() } })
                            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
                        VStack(spacing: 12) {
                            DashboardDataCard(value: state, idle: DashboardStatus.stopped,
                                active: data.status?.coreRunning == true, ready: cardsReady, slot: 0) { displayed, _ in
                                nodeCard(state: displayed).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }.frame(height: cardSpace * 0.344)
                            DashboardDataCard(value: rates, idle: Optional<[Double]>.none,
                                active: data.status?.coreRunning == true, ready: cardsReady, slot: 1) { displayed, _ in
                                trafficCard(rates: displayed, state: state).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }.frame(height: cardSpace * 0.304)
                            RecentConnectionsCard(connections: data.connections,
                                coreRunning: data.status?.coreRunning == true, dataReady: cardsReady)
                                .frame(height: cardSpace * 0.352)
                        }.frame(width: geometry.size.width * 0.325, height: max(0, geometry.size.height - 24))
                            .padding(.trailing, 12).padding(.vertical, 12)
                    }
                }

            }
        }
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
    private func nodeCard(state: DashboardStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                statusIcon(.shieldActive, title: "后台服务", enabled: data.helperReady)
                Rectangle().fill(DashboardTheme.line.opacity(0.5)).frame(width: 0.5, height: 32)
                statusIcon(.transfer, title: "系统代理", enabled: state == .system)
                Rectangle().fill(DashboardTheme.line.opacity(0.5)).frame(width: 0.5, height: 32)
                statusIcon(.link, title: "TUN", enabled: state == .tun)
            }.padding(.top, 2).padding(.bottom, 10)
            rule
            Text("当前节点").font(AppFont.caption).foregroundStyle(DashboardTheme.muted).padding(.top, 11)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(data.nodePlace?.displayCity ?? "位置未知").font(AppFont.size(21)).lineLimit(1).minimumScaleFactor(0.75)
                Text("·").foregroundStyle(DashboardTheme.muted)
                Text(nodeName).font(AppFont.size(14)).foregroundStyle(DashboardTheme.muted)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).help(nodeName)
            }.padding(.top, 6).padding(.bottom, 8)
            Text(protocols).font(AppFont.size(10.5)).foregroundStyle(DashboardTheme.muted)
                .lineLimit(1).minimumScaleFactor(0.8).help("节点配置：" + protocols + "。ALPN 是配置值，不代表已协商的协议。")
            Text("Xray " + (data.status?.installedXrayVersion ?? "版本待读取"))
                .font(AppFont.size(10))
                .foregroundStyle(DashboardTheme.muted.opacity(0.75)).lineLimit(1).padding(.top, 7)
        }.padding(12).dashboardPanel()
    }
    private func statusIcon(_ icon: ControlAsset, title: String, enabled: Bool) -> some View {
        VStack(spacing: 6) {
            RealityGlyph(asset: icon, size: 21, color: enabled ? DashboardTheme.accent : DashboardTheme.muted).frame(height: 28)
            Text(title).font(AppFont.caption).frame(height: 16)
        }.foregroundStyle(enabled ? DashboardTheme.accent : DashboardTheme.muted)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore).accessibilityLabel(title + (enabled ? "已就绪" : "未开启"))
    }
    private var rule: some View { Rectangle().fill(DashboardTheme.line.opacity(0.7)).frame(height: 0.5) }
    private func trafficCard(rates: [Double]?, state: DashboardStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时流量").font(AppFont.size(13))
            HStack(spacing: 10) {
                VStack(spacing: 8) {
                    trafficMetric("代理上传", icon: .upload, value: DashboardStatus.rateParts(rates?[0]), color: DashboardTheme.proxyUpload)
                    trafficMetric("直连上传", icon: .upload, value: DashboardStatus.rateParts(rates?[2]), color: DashboardTheme.directUpload)
                }
                Rectangle().fill(DashboardTheme.line).frame(width: 0.5, height: 42)
                VStack(spacing: 8) {
                    trafficMetric("代理下载", icon: .download, value: DashboardStatus.rateParts(rates?[1]), color: DashboardTheme.proxyDownload)
                    trafficMetric("直连下载", icon: .download, value: DashboardStatus.rateParts(rates?[3]), color: DashboardTheme.directDownload)
                }
            }
            rule
            Text("节点累计").font(AppFont.size(13))
            HStack(spacing: 10) {
                trafficMetric("代理累计上传", icon: .upload, value: DashboardStatus.amountParts(data.status?.statisticsEnabled == true ? node?.totalUp : nil),
                              color: DashboardTheme.proxyUpload)
                Rectangle().fill(DashboardTheme.line).frame(width: 0.5, height: 22)
                trafficMetric("代理累计下载", icon: .download, value: DashboardStatus.amountParts(data.status?.statisticsEnabled == true ? node?.totalDown : nil),
                              color: DashboardTheme.proxyDownload)
            }
        }.padding(12).dashboardPanel()
            .help(DashboardStatus.trafficDescription(state: state, enabled: data.status?.trafficEnabled, hasSample: rates != nil)
                + "；第一行青／紫为代理上传／下载，第二行绿／橙为直连上传／下载。直连仅包含经过 Xray 的流量；节点累计仅统计当前节点的代理流量。")
    }
    private func trafficMetric(_ title: String, icon: ControlAsset, value: DashboardMetricValue, color: Color) -> some View {
        DashboardTrafficMetric(title: title, icon: icon, value: value, color: color)
    }
}

struct DashboardTrafficMetric: View {
    let title: String
    let icon: ControlAsset
    let value: DashboardMetricValue
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            RealityGlyph(asset: icon, size: 14, color: color)
                .frame(width: 14, height: 20)
            DashboardNumericText(text: value.number, size: 14, color: DashboardTheme.text)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(value.unit).frame(width: 43, alignment: .trailing)
        }.font(AppFont.size(14)).monospacedDigit().lineLimit(1)
            .foregroundStyle(DashboardTheme.muted).frame(maxWidth: .infinity).frame(height: 22)
            .accessibilityElement(children: .ignore).accessibilityLabel(title + " " + value.text)
            .help(title + "：" + value.text)
    }
}

struct RecentConnectionsCard: View {
    @StateObject private var rowScheduler = RecentRowFlipScheduler()
    let connections: [GlobeConnection]
    let coreRunning: Bool
    var dataReady = true
    var body: some View {
        DashboardDataCard(value: connections, idle: [], active: coreRunning,
                          ready: dataReady && !connections.isEmpty, slot: 2, contentWhileHidden: true) { displayed, presentedActive in
            rows(displayed, active: presentedActive)
        }
    }
    private func rows(_ connections: [GlobeConnection], active: Bool) -> some View {
        GeometryReader { geometry in
            if connections.isEmpty {
                Text(coreRunning ? "等待新的连接记录" : "开启代理后显示连接")
                    .font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = Array(connections.prefix(7))
                let rowHeight = max(0, (geometry.size.height - 24) / 7)
                VStack(spacing: 4) {
                    // Stable slots share a two-turn budget; each keeps its own bitmap cache.
                    ForEach(rows.indices, id: \.self) { index in
                        RecentConnectionRow(connection: rows[index], slot: index, rowOffset: CGFloat(index) - CGFloat(rows.count - 1) / 2, scheduler: rowScheduler, active: active).frame(height: rowHeight)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }.padding(12).frame(maxHeight: .infinity).dashboardPanel()
    }
}

struct RecentConnectionRow: View {
    let connection: GlobeConnection
    let slot: Int
    let rowOffset: CGFloat
    let scheduler: RecentRowFlipScheduler
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.dashboardMotionEnabled) private var motion
    @Environment(\.dashboardFlipsEnabled) private var flips
    var body: some View {
        let location = connection.place.map { " · " + $0.displayCity + "（IP/DNS 估计）" } ?? " · 位置未知"
        CachedRecentRow(face: RecentRowFace(connection), slot: slot, rowOffset: rowOffset, scheduler: scheduler,
                        motion: motion, flips: flips && active, reduced: reduced)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(connection.host + "，" + connection.routeTitle)
            .help(connection.host + ":\(connection.port) · " + connection.routeTitle + location)
    }
}

private extension View {
    func dashboardPanel() -> some View {
        modifier(RealityPanelModifier())
    }
}
