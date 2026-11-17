import AppKit

/// Freeze synchronously, then hand control to AppKit in the same event turn.
@MainActor final class WindowMinimizeCoordinator {
    static let shared = WindowMinimizeCoordinator()
    private weak var pendingWindow: NSWindow?
    private let minimize: @MainActor (NSWindow) -> Void

    init(minimize: @escaping @MainActor (NSWindow) -> Void = { $0.miniaturize(nil) }) {
        self.minimize = minimize
    }
    func isPreparing(_ window: NSWindow) -> Bool { pendingWindow === window }

    func request(_ window: NSWindow) {
        guard pendingWindow == nil, window.isVisible, !window.isMiniaturized,
              !NSApp.isHidden else { return }
        pendingWindow = window
        NotificationCenter.default.post(name: .windowMinimizePreparationBegan, object: window)
        // A synchronous observer can close/hide the window or cancel the request.
        guard pendingWindow === window else { return }
        defer { cancel(for: window) }
        guard window.isVisible, !window.isMiniaturized, !NSApp.isHidden else { return }
        minimize(window)
    }

    func cancel(for window: NSWindow? = nil) {
        if let window, pendingWindow !== window { return }
        guard let pending = pendingWindow else { return }
        pendingWindow = nil
        NotificationCenter.default.post(name: .windowMinimizePreparationEnded, object: pending)
    }
}

extension Notification.Name {
    static let windowMinimizePreparationBegan = Notification.Name("v2rayM.windowMinimizePreparationBegan")
    static let windowMinimizePreparationEnded = Notification.Name("v2rayM.windowMinimizePreparationEnded")
}
