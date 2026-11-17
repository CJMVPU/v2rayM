import SwiftUI
import Combine
import V2rayMKit

/// One value snapshot isolates the retained surface from background telemetry.
/// The model keeps collecting data; only presentation is suspended.
struct DashboardSnapshot: Equatable {
    var now: Date
    var state: DashboardStatus
    var status: RuntimeStatus?
    var profiles: [Profile]
    var trend: TrafficTrend
    var trendCatchUp: TrafficTrendCatchUp?
    var connections: [GlobeConnection]
    var nodePlace: GlobePlace?
    var helperReady: Bool
    var connecting: Bool
    @MainActor init(model: AppModel, now: Date = Date()) {
        self.now = now; state = model.displayStatus(at: now); status = model.status
        profiles = model.profiles; trend = model.trafficTrend
        connections = model.dashboard.connections; nodePlace = model.dashboard.nodePlace
        helperReady = model.ready && model.tun?.helperAvailable == true
        connecting = model.connecting
    }
}

@MainActor final class DashboardPresentationSource: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot
    let model: AppModel
    private var enabled = false
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?
    private var queued = false
    private var frozenAt: Date?
    private var catchUp: TrafficTrendCatchUp?
    init(model: AppModel) { self.model = model; snapshot = DashboardSnapshot(model: model) }
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        subscriptions.removeAll(); timer?.invalidate(); timer = nil
        guard enabled else { frozenAt = Date(); return }
        let resumedAt = Date()
        if let frozenAt {
            let displayedAt = catchUp?.displayDate(at: frozenAt) ?? frozenAt
            catchUp = TrafficTrendCatchUp(previous: snapshot.trend, displayedAt: displayedAt,
                latest: model.trafficTrend, resumedAt: resumedAt, retained: catchUp?.samples ?? [])
        }
        frozenAt = nil
        refresh()
        for publisher in [model.objectWillChange, model.telemetry.objectWillChange, model.dashboard.objectWillChange] {
            subscriptions.append(publisher.sink { [weak self] in self?.scheduleRefresh() })
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func scheduleRefresh() {
        guard enabled, !queued else { return }
        queued = true
        // ObservableObject emits before mutation; combine a burst into one read.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false; self.refresh()
        }
    }
    private func refresh() {
        guard enabled else { return }
        var latest = DashboardSnapshot(model: model)
        latest.trendCatchUp = catchUp
        snapshot = latest
    }
    deinit { timer?.invalidate() }
}
