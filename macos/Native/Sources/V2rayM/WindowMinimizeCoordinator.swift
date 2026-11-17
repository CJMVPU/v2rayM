import AppKit

/// Let the frozen surface commit before asking WindowServer to animate it.
/// This is a scheduling gap, not a GPU-idle fence. Never block the main thread.
@MainActor final class WindowMinimizeCoordinator {
    static let shared = WindowMinimizeCoordinator()
    let preparationDelay: TimeInterval
    private weak var pendingWindow: NSWindow?
    private var worker: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    private var generation = 0
    private let minimize: @MainActor (NSWindow) -> Void

    init(preparationDelay: TimeInterval = 0.18,
         minimize: @escaping @MainActor (NSWindow) -> Void = { $0.miniaturize(nil) }) {
        self.preparationDelay = preparationDelay
        self.minimize = minimize
    }

    func isPreparing(_ window: NSWindow) -> Bool { pendingWindow === window }

    func request(_ window: NSWindow) {
        guard pendingWindow == nil, window.isVisible, !window.isMiniaturized,
              !NSApp.isHidden else { return }
        generation += 1
        let request = generation
        pendingWindow = window
        for (name, object) in [
            (NSWindow.willCloseNotification, window as Any?),
            (NSWindow.didDeminiaturizeNotification, window as Any?),
            (NSWindow.willMiniaturizeNotification, window as Any?),
            (NSApplication.willHideNotification, nil),
            (NSApplication.willResignActiveNotification, nil)
        ] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        // Publication and display-link invalidation happen synchronously here;
        // SwiftUI then gets the intervening run-loop turns to settle its surfaces.
        NotificationCenter.default.post(name: .windowMinimizePreparationBegan, object: window)
        worker = Task { @MainActor [weak self, weak window] in
            guard let delay = self?.preparationDelay else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            guard let window, self.pendingWindow === window else { self.cancel(); return }
            guard window.isVisible, !window.isMiniaturized, !NSApp.isHidden else {
                self.cancel(); return
            }
            // Our own minimization changes activation too. Remove cancellation
            // observers first, but keep the preparation latch until AppKit returns.
            self.removeObservations()
            self.worker = nil
            self.minimize(window)
            self.pendingWindow = nil
            NotificationCenter.default.post(name: .windowMinimizePreparationEnded, object: window)
        }
    }

    func cancel(for window: NSWindow? = nil) {
        if let window, pendingWindow !== window { return }
        generation += 1
        worker?.cancel(); worker = nil
        removeObservations()
        guard let pending = pendingWindow else { return }
        pendingWindow = nil
        NotificationCenter.default.post(name: .windowMinimizePreparationEnded, object: pending)
    }

    private func removeObservations() {
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
    }
    deinit {
        worker?.cancel()
        observations.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

extension Notification.Name {
    static let windowMinimizePreparationBegan = Notification.Name("v2rayM.windowMinimizePreparationBegan")
    static let windowMinimizePreparationEnded = Notification.Name("v2rayM.windowMinimizePreparationEnded")
}
