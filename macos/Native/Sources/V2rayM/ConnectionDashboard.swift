import AppKit
import SwiftUI
import V2rayMKit

/// Directional gauges use the last minute's sampled peak as their full scale.
struct ConnectionDashboard: View {
    let state: DashboardStatus
    let city: String
    let nodeName: String
    let node: Profile?
    let startedAt: String?
    let coreRunning: Bool
    let rates: [Double]?
    let trend: TrafficTrend
    var catchUp: TrafficTrendCatchUp? = nil
    let trafficEnabled: Bool?
    let now: Date
    let connecting: Bool
    let reconnect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardMotionEnabled) private var windowVisible
    @State private var discHovered = false
    private var running: Bool { state.active || state == .local }
    private var mode: String {
        switch state {
        case .tun: return "TUN"
        case .system: return "系统代理"
        case .local: return "本地代理"
        case .stopped: return "已关闭"
        default: return "待确认"
        }
    }
    private var statusColor: Color {
        if running { return .green }
        return [.recovering, .faulted, .stale, .changing, .updating].contains(state) ? .orange : DashboardTheme.muted
    }
    var body: some View {
        GeometryReader { geometry in
            let trendHeight: CGFloat = 92
            let gap: CGFloat = 12
            let gaugeHeight = max(0, geometry.size.height - trendHeight - gap)
            let diameter = max(0, min(384, gaugeHeight - 80, geometry.size.width - 24))
            VStack(spacing: gap) {
                ZStack(alignment: .topLeading) {
                    HStack {
                        badge("模式", value: mode)
                        Spacer()
                        badge("内核", value: "Xray")
                    }.padding(.horizontal, 12).padding(.top, 14)
                    activityRing(diameter: diameter)
                        .position(x: geometry.size.width / 2, y: gaugeHeight / 2)
                    HStack {
                        badge("协议", value: node?.protocol.uppercased() ?? "—")
                        Spacer()
                        badge("延迟", value: (node?.delay ?? 0) > 0 ? "\(node?.delay ?? 0) ms" : "—")
                    }.padding(.horizontal, 12).padding(.bottom, 12).frame(maxHeight: .infinity, alignment: .bottom)
                }.frame(height: gaugeHeight)
                TrafficTrendView(trend: trend, catchUp: catchUp, now: trend.displayDate(at: now),
                    animate: coreRunning && trafficEnabled == true && windowVisible && !reduceMotion,
                    emptyTitle: DashboardStatus.trafficDescription(state: state, enabled: trafficEnabled, hasSample: false),
                    awaitingSample: running && coreRunning && trafficEnabled == true)
                    .frame(height: trendHeight)
            }
        }
    }
    private func badge(_ title: String, value: String) -> some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(DashboardTheme.muted)
            Text(value).foregroundStyle(.primary)
        }.font(AppFont.caption).padding(.horizontal, 10).padding(.vertical, 6)
            .background(DashboardTheme.panel, in: RoundedRectangle(cornerRadius: 7))
            .modifier(DashboardRelief(radius: 7))
    }
    private func activityRing(diameter: CGFloat) -> some View {
        let peaks = trend.peaks(at: now)
        let fractions = (0..<4).map { index -> Double in
            guard running, let rates, rates.indices.contains(index), peaks[index] > 0 else { return 0 }
            return min(1, max(0, rates[index] / peaks[index]))
        }
        let duration = coreRunning ? DashboardStatus.duration(since: startedAt, now: now) : "—"
        return ZStack {
            ZStack {
                ring(diameter: diameter, color: DashboardTheme.directUpload, fraction: fractions[2])
                ring(diameter: max(0, diameter - 22), color: DashboardTheme.directDownload, fraction: fractions[3])
                ring(diameter: max(0, diameter - 44), color: DashboardTheme.cyan, fraction: fractions[0])
                ring(diameter: max(0, diameter - 66), color: DashboardTheme.purple, fraction: fractions[1])
            }
            .accessibilityHidden(true)
            ZStack {
                DashboardDiscSurface(hovered: discHovered)
                VStack(spacing: 9) {
                    Image(systemName: running ? "shield.lefthalf.filled" : state == .recovering ? "arrow.triangle.2.circlepath" : "shield")
                        .font(.system(size: 22)).foregroundStyle(statusColor)
                    Text(city).font(AppFont.size(25)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(nodeName).font(AppFont.size(12)).foregroundStyle(DashboardTheme.muted)
                        .lineLimit(1).truncationMode(.middle)
                    DashboardNumericText(text: duration, size: 24).padding(.top, 4)
                    Text(connecting && state == .offline ? "正在连接本地服务" : state.title)
                        .font(AppFont.size(12)).foregroundStyle(statusColor).lineLimit(1)
                    Button("重新连接服务", action: reconnect).font(AppFont.caption)
                        .disabled(state != .offline || connecting)
                        .opacity(state == .offline && !connecting ? 1 : 0)
                        .accessibilityHidden(state != .offline || connecting)
                }.padding(.horizontal, 18)
            }.frame(width: max(0, diameter - Self.discInset * 2), height: max(0, diameter - Self.discInset * 2))
                .modifier(DashboardActivationFlip(active: coreRunning, kind: .disc))
        }.frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): discHovered = Self.containsDisc(location, diameter: diameter)
                case .ended: discHovered = false
                }
            }
            .onDisappear { discHovered = false }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: discHovered)
    }
    static let discInset: CGFloat = 48

    /// Hover coordinates belong to the whole gauge, but only the inset disc lights up.
    static func containsDisc(_ point: CGPoint, diameter: CGFloat) -> Bool {
        let radius = max(0, diameter / 2 - discInset)
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        return radius > 0 && dx * dx + dy * dy <= radius * radius
    }

    private func ring(diameter: CGFloat, color: Color, fraction: Double) -> some View {
        DashboardRing(fraction: fraction, color: color, animate: windowVisible && !reduceMotion)
            .frame(width: max(0, diameter - 4), height: max(0, diameter - 4))
    }
}

/// Hover changes only the surface, preserving ring geometry and hit testing.
struct DashboardDiscSurface: View {
    let hovered: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.165))
            Circle().fill(Color.primary.opacity(hovered ? 0.13 : 0))
            Circle().strokeBorder(
                LinearGradient(colors: [DashboardTheme.cyan, DashboardTheme.purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(hovered ? 0.85 : 0), lineWidth: 2)
                .shadow(color: DashboardTheme.cyan.opacity(hovered ? 0.32 : 0), radius: 14)
        }
    }
}

struct TrafficTrendView: View {
    let trend: TrafficTrend
    var catchUp: TrafficTrendCatchUp? = nil
    let now: Date
    let animate: Bool
    let emptyTitle: String
    var awaitingSample = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardMotionEnabled) private var presentationActive
    @State private var finishedCatchUp: Date?
    @State private var scaleFrom = 1.0
    @State private var scaleTo = 1.0
    @State private var scaleChanged = Date.distantPast
    @State private var sampleArrived = Date.distantPast
    @State private var retirement: TrafficTrendRetirement?
    private func eased(_ elapsed: Double) -> Double {
        let t = min(1, max(0, elapsed / 1.2))
        return t * t * (3 - 2 * t)
    }
    private func scale(at date: Date) -> Double {
        scaleFrom + (scaleTo - scaleFrom) * eased(date.timeIntervalSince(scaleChanged))
    }
    var body: some View {
        let points = trend.plotSamples(at: now)
        let maximum = max(1, (points.map(\.maximum).max() ?? 0) * 1.12)
        let peak = trend.peaks(at: now).max() ?? 0
        let peakLabel = points.contains { now.timeIntervalSince($0.date) < 60 } ? DashboardStatus.rate(peak) : "—"
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("流量趋势").font(AppFont.size(12))
                Text("近5分钟 · 1分钟均速").font(AppFont.size(10)).foregroundStyle(DashboardTheme.muted)
                Text("峰值 " + peakLabel)
                    .font(AppFont.size(10)).monospacedDigit().foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 0)
                legend("代理 ↑", color: DashboardTheme.cyan)
                legend("代理 ↓", color: DashboardTheme.purple)
                legend("直连 ↑", color: DashboardTheme.directUpload)
                legend("直连 ↓", color: DashboardTheme.directDownload)
            }
            plot(points: points, maximum: maximum)
        }.padding(.top, 7)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
            .onAppear { scaleFrom = maximum; scaleTo = maximum }
            .onChange(of: maximum) { _, value in
                let date = Date()
                scaleFrom = scale(at: date); scaleTo = value; scaleChanged = date
            }
            .onChange(of: trend) { old, new in
                if animate, old.pausedAt != nil, new.pausedAt == nil {
                    retirement = TrafficTrendRetirement(previous: old, resumedAt: Date())
                } else if new.pausedAt != nil { retirement = nil }
            }
            .onChange(of: animate) { _, enabled in if !enabled { retirement = nil } }
            .task(id: retirement?.startedAt) {
                guard retirement != nil else { return }
                do { try await Task.sleep(for: .seconds(TrafficTrendRetirement.duration)) }
                catch { return }
                retirement = nil
            }
            .task(id: presentationActive && !reduceMotion ? catchUp?.startedAt : nil) {
                guard presentationActive, !reduceMotion, let catchUp else { return }
                do { try await Task.sleep(for: .seconds(max(0, catchUp.duration - Date().timeIntervalSince(catchUp.startedAt)))) }
                catch { return }
                guard !Task.isCancelled else { return }
                // Hand off at the same scale/full endpoint, rather than falling
                // back to an older scale or last-segment reveal animation.
                scaleFrom = scaleTo; scaleChanged = .distantPast
                sampleArrived = .distantPast
                finishedCatchUp = catchUp.startedAt
            }
            .onChange(of: points.last?.id) { _, _ in sampleArrived = Date() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("近五分钟代理及直连流量趋势，每五秒采样，显示一分钟均速。最近一分钟峰值 " + peakLabel + "。\(trend.visible(at: now).count) 个有效采样点。" + (points.isEmpty ? emptyTitle : ""))
    }
    private func plot(points: [TrafficTrendSample], maximum: Double) -> some View {
            GeometryReader { geometry in
                let replaying = catchUp != nil && catchUp?.startedAt != finishedCatchUp && !reduceMotion
                let history = replaying ? (catchUp?.merged(with: trend) ?? []) : []
                let input = TrendLayerInput(points)
                let replayInput = TrendLayerInput(history)
                let retired = retirement.map { TrendLayerInput($0.samples) }
                DashboardTrendPlot(configuration: TrendFrameConfiguration(
                    input: input, replayInput: replayInput, retired: retired, now: now, maximum: maximum,
                    animate: animate, presentationActive: presentationActive, replaying: replaying,
                    catchUp: catchUp, retirement: retirement, scaleFrom: scaleFrom, scaleTo: scaleTo,
                    scaleChanged: scaleChanged, sampleArrived: sampleArrived))
            }.overlay {
                if points.isEmpty && retirement == nil {
                    if awaitingSample {
                        VStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 4) {
                                Spacer(minLength: 0)
                                ForEach(0..<4) { index in
                                    Circle().fill([DashboardTheme.cyan, DashboardTheme.purple,
                                                   DashboardTheme.directUpload, DashboardTheme.directDownload][index])
                                        .frame(width: 4, height: 4)
                                }
                            }
                        }.padding(.trailing, 2).padding(.bottom, 1)
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomTrailing)))
                    } else {
                        Text(emptyTitle).font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                            .transition(.opacity)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: awaitingSample)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: points.isEmpty)
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle().fill(color).frame(width: 4, height: 4)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            Text(title).font(AppFont.size(10)).foregroundStyle(DashboardTheme.muted)
        }.fixedSize()
    }
}
