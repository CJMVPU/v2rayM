import Foundation

/// Owns every observation until it returns, including canceled requests. A forced
/// refresh replaces the queued work, never overlaps a slow request for that topic.
@MainActor public final class ObservationScheduler {
    private typealias Work = @MainActor () async -> Void
    private var running: [String: Task<Void, Never>] = [:]
    private var pending: [String: Work] = [:]
    private var completed: [String: Date] = [:]
    private let clock: any NativeClock

    public init(clock: any NativeClock) { self.clock = clock }

    public func schedule(_ topic: String, interval: TimeInterval, force: Bool,
                         work: @escaping @MainActor () async -> Void) {
        if let current = running[topic] {
            if force {
                pending[topic] = work
                current.cancel()
            }
            return
        }
        if !force, let date = completed[topic] {
            let elapsed = clock.now().timeIntervalSince(date)
            if elapsed >= 0 && elapsed < interval { return }
        }
        start(topic, work: work)
    }

    private func start(_ topic: String, work: @escaping Work) {
        running[topic] = Task { [weak self] in
            if !Task.isCancelled { await work() }
            guard let self else { return }
            self.running[topic] = nil
            if !Task.isCancelled { self.completed[topic] = self.clock.now() }
            if let next = self.pending.removeValue(forKey: topic) {
                // A fresh task is required: the superseded task remains canceled.
                self.start(topic, work: next)
            }
        }
    }

    public func waitUntilIdle() async {
        while !running.isEmpty {
            let tasks = Array(running.values)
            for task in tasks { await task.value }
        }
    }

    public func cancel() {
        pending.removeAll()
        completed.removeAll()
        running.values.forEach { $0.cancel() }
        // Retain task ownership so shutdown can drain uncooperative requests.
    }
}
