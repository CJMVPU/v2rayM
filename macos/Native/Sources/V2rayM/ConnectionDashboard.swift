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
    let trafficEnabled: Bool?
    let now: Date
    let connecting: Bool
    let reconnect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowVisible = false
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
            let diameter = max(0, min(340, 2 * gaugeHeight - geometry.size.width))
            let inset = (geometry.size.width - diameter) / 2
            VStack(spacing: gap) {
                ZStack(alignment: .topLeading) {
                    HStack {
                        badge("模式", value: mode)
                        Spacer()
                        badge("内核", value: "Xray")
                    }.padding(.horizontal, 12).padding(.top, 26)
                    activityRing(diameter: diameter)
                        .position(x: geometry.size.width / 2, y: inset + diameter / 2 - 20)
                    HStack {
                        badge("协议", value: node?.protocol.uppercased() ?? "—")
                        Spacer()
                        badge("延迟", value: (node?.delay ?? 0) > 0 ? "\(node?.delay ?? 0) ms" : "—")
                    }.padding(.horizontal, 12).frame(maxHeight: .infinity, alignment: .bottom)
                }.frame(height: gaugeHeight).offset(y: -12)
                TrafficTrendView(trend: trend, now: now, animate: windowVisible && !reduceMotion,
                    emptyTitle: DashboardStatus.trafficDescription(state: state, enabled: trafficEnabled, hasSample: false))
                    .frame(height: trendHeight)
            }
        }
        .background(DashboardWindowVisibility(visible: $windowVisible))
    }
    private func badge(_ title: String, value: String) -> some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(DashboardTheme.muted)
            Text(value).foregroundStyle(.primary)
        }.font(AppFont.caption).padding(.horizontal, 10).padding(.vertical, 6)
            .background(DashboardTheme.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
    private func activityRing(diameter: CGFloat) -> some View {
        let peaks = trend.peaks(at: now)
        let upload = running && peaks[0] > 0 ? min(1, max(0, (rates?.first ?? 0) / max(peaks[0], 0.000001))) : 0
        let download = running && peaks[1] > 0 ? min(1, max(0, (rates?.dropFirst().first ?? 0) / max(peaks[1], 0.000001))) : 0
        let animate = windowVisible && !reduceMotion
        return ZStack {
            ZStack {
                ring(diameter: diameter, color: DashboardTheme.cyan, fraction: upload)
                ring(diameter: max(0, diameter - 22), color: DashboardTheme.purple, fraction: download)
            }
            .animation(animate ? .easeInOut(duration: 1.2) : nil, value: upload)
            .animation(animate ? .easeInOut(duration: 1.2) : nil, value: download)
            .accessibilityHidden(true)
            DashboardDiscSurface(hovered: discHovered).padding(26)
            VStack(spacing: 9) {
                Image(systemName: running ? "shield.lefthalf.filled" : state == .recovering ? "arrow.triangle.2.circlepath" : "shield")
                    .font(.system(size: 22)).foregroundStyle(statusColor)
                Text(city).font(AppFont.size(25)).lineLimit(1).minimumScaleFactor(0.7)
                Text(nodeName).font(AppFont.size(12)).foregroundStyle(DashboardTheme.muted)
                    .lineLimit(1).truncationMode(.middle)
                Text(coreRunning ? DashboardStatus.duration(since: startedAt, now: now) : "—")
                    .font(AppFont.size(24)).monospacedDigit().padding(.top, 4)
                Text(connecting && state == .offline ? "正在连接本地服务" : state.title)
                    .font(AppFont.size(12)).foregroundStyle(statusColor).lineLimit(1)
                if state == .offline && !connecting {
                    Button("重新连接服务", action: reconnect).font(AppFont.caption)
                }
            }.padding(.horizontal, 44)
        }.frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .onHover { discHovered = $0 }
            .onDisappear { discHovered = false }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: discHovered)
    }
    private func ring(diameter: CGFloat, color: Color, fraction: Double) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90))
        }.frame(width: max(0, diameter - 4), height: max(0, diameter - 4))
    }
}

/// Hover changes only the surface, preserving ring geometry and hit testing.
struct DashboardDiscSurface: View {
    let hovered: Bool
    var body: some View {
        ZStack {
            Circle().fill(DashboardTheme.panel.opacity(0.65))
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
    let now: Date
    let animate: Bool
    let emptyTitle: String
    @State private var scaleFrom = 1.0
    @State private var scaleTo = 1.0
    @State private var scaleChanged = Date.distantPast
    @State private var sampleArrived = Date.distantPast
    private func eased(_ elapsed: Double) -> Double {
        let t = min(1, max(0, elapsed / 1.2))
        return t * t * (3 - 2 * t)
    }
    private func scale(at date: Date) -> Double {
        scaleFrom + (scaleTo - scaleFrom) * eased(date.timeIntervalSince(scaleChanged))
    }
    var body: some View {
        let points = trend.visible(at: now)
        let maximum = max(1, (points.map { max($0.upload, $0.download) }.max() ?? 0) * 1.12)
        let peak = trend.peaks(at: now).max() ?? 0
        let peakLabel = points.contains { now.timeIntervalSince($0.date) < 60 } ? DashboardStatus.rate(peak) : "—"
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text("流量趋势").font(AppFont.size(12))
                Text("近5分钟 · 1分钟均速").font(AppFont.size(10)).foregroundStyle(DashboardTheme.muted)
                Text("峰值 " + peakLabel)
                    .font(AppFont.size(10)).monospacedDigit().foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 0)
                legend("上传", color: DashboardTheme.cyan)
                legend("下载", color: DashboardTheme.purple)
            }
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !animate || points.isEmpty)) { timeline in
                let date = animate ? timeline.date : now
                let ceiling = animate ? scale(at: date) : maximum
                let reveal = animate ? eased(date.timeIntervalSince(sampleArrived)) : 1
                Canvas { context, size in
                    for index in 0...6 {
                        var grid = Path()
                        let y = 3 + Double(index) / 6 * max(0, size.height - 6)
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(grid, with: .color(.primary.opacity(index == 6 ? 0.13 : 0.08)), lineWidth: 0.5)
                    }
                    for (key, color) in [(\TrafficTrendSample.upload, DashboardTheme.cyan), (\TrafficTrendSample.download, DashboardTheme.purple)] {
                        var line = Path()
                        var previous: TrafficTrendSample?
                        var previousPosition: CGPoint?
                        for point in points {
                            let age = date.timeIntervalSince(point.date)
                            let x = 2 + (1 - age / TrafficTrend.duration) * max(0, size.width - 4)
                            let y = size.height - 3 - point[keyPath: key] / max(1, ceiling) * max(0, size.height - 6)
                            var position = CGPoint(x: x, y: y)
                            if let previousPosition, previous?.segment == point.segment {
                                if point.id == points.last?.id {
                                    position.x = previousPosition.x + (position.x - previousPosition.x) * reveal
                                    position.y = previousPosition.y + (position.y - previousPosition.y) * reveal
                                }
                                // Horizontal tangents make a smooth, bounded curve: no
                                // spline overshoot, invented peaks or bridges across gaps.
                                let middle = (previousPosition.x + position.x) / 2
                                line.addCurve(to: position,
                                    control1: CGPoint(x: middle, y: previousPosition.y),
                                    control2: CGPoint(x: middle, y: position.y))
                            } else {
                                line.move(to: position)
                                context.fill(Path(ellipseIn: CGRect(x: position.x - 1.2, y: position.y - 1.2, width: 2.4, height: 2.4)), with: .color(color))
                            }
                            previous = point; previousPosition = position
                        }
                        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }.clipped()
            }.overlay {
                if points.isEmpty { Text(emptyTitle).font(AppFont.caption).foregroundStyle(DashboardTheme.muted) }
            }
        }.padding(.top, 7)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
            .onAppear { scaleFrom = maximum; scaleTo = maximum }
            .onChange(of: maximum) { _, value in
                let date = Date()
                scaleFrom = scale(at: date); scaleTo = value; scaleChanged = date
            }
            .onChange(of: points.last?.id) { _, _ in sampleArrived = Date() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("近五分钟代理流量趋势，每五秒采样，显示一分钟均速。最近一分钟峰值 " + peakLabel + "。\(points.count) 个有效采样点。" + (points.isEmpty ? emptyTitle : ""))
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(title).font(AppFont.size(10)).foregroundStyle(DashboardTheme.muted)
        }
    }
}

/// TimelineView is explicitly paused when the window closes, minimizes or is occluded.
private struct DashboardWindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool
    func makeNSView(context: Context) -> Watcher { Watcher { visible = $0 } }
    func updateNSView(_ view: Watcher, context: Context) {}
    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }
    final class Watcher: NSView {
        private let changed: (Bool) -> Void
        private var observations: [NSObjectProtocol] = []
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    self?.update(closing: note.name == NSWindow.willCloseNotification)
                })
            }
            update()
        }
        private func update(closing: Bool = false) {
            let value = !closing && window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
            DispatchQueue.main.async { [weak self] in self?.changed(value) }
        }
        func stop() { observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll() }
        deinit { stop() }
    }
}
