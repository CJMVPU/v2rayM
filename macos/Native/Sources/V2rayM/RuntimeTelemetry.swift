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
    @Published var entries: [LogEntry] = []
}
struct ObservedLogConsole: View {
    @ObservedObject var state: LogObservation
    var body: some View { LogConsole(entries: state.entries) }
}
