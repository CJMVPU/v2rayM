import SwiftUI
import V2rayMKit

/// High-frequency observations publish only to their own visible consumers.
@MainActor final class RuntimeTelemetry: ObservableObject {
    @Published var status: RuntimeStatus?
    @Published private(set) var trend = TrafficTrend()
    func record(_ state: RuntimeStatus, now: Date) {
        var next = trend
        next.record(state, now: now)
        if next != trend { trend = next }
    }
}
@MainActor final class LogObservation: ObservableObject {
    @Published var entries: [LogEntry] = [] { didSet { position = nil } }
    private var epoch = UUID()
    private(set) var position: NativeLogDocument.HistoryPosition?

    func restartHistory() { epoch = UUID(); position = nil }
    func publish(_ history: RollingLogBuffer) {
        entries = history.entries
        position = .init(epoch: epoch, headOffset: history.headOffset)
    }
    // One reader per app window retains selection and the reading position across navigation.
    // Opening another page stops rendering; the next visit applies the accumulated delta.
    private(set) lazy var document = NativeLogDocument()
}
struct ObservedLogConsole: View {
    @ObservedObject var state: LogObservation
    var body: some View {
        LogConsole(entries: state.entries, position: state.position, document: state.document)
            .overlay {
                if state.entries.isEmpty {
                    Text("暂无日志").font(AppFont.body).foregroundStyle(DashboardTheme.muted)
                        .allowsHitTesting(false)
                }
            }
    }
}
