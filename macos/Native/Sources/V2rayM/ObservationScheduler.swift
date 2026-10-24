import Foundation
import V2rayMKit

/// Metadata never holds up connection-health publication. One request per topic
/// is in flight; forced refreshes supersede old work after a user mutation.
@MainActor final class ObservationScheduler {
    private struct Entry { let id: UUID; let task: Task<Void, Never> }
    private var running: [String: Entry] = [:]
    private var completed: [String: Date] = [:]
    private let clock: any NativeClock
    init(clock: any NativeClock) { self.clock = clock }
    func schedule(_ topic: String, interval: TimeInterval, force: Bool,
                  work: @escaping @MainActor () async -> Void) {
        if !force {
            guard running[topic] == nil else { return }
            if let date = completed[topic], clock.now().timeIntervalSince(date) < interval { return }
        }
        running[topic]?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            await work()
            guard let self, self.running[topic]?.id == id else { return }
            self.running[topic] = nil; self.completed[topic] = self.clock.now()
        }
        running[topic] = Entry(id: id, task: task)
    }
    func waitUntilIdle() async {
        let tasks = running.values.map(\.task)
        for task in tasks { await task.value }
    }
    func cancel() { running.values.forEach { $0.task.cancel() }; running.removeAll() }
}
