import AppKit
import SwiftUI
import CoreGraphics

struct DashboardVisibilityState: Equatable {
    var windowVisible = false
    var minimized = false
    var occluded = true
    var appHidden = false
    var locked = false
    var sleeping = false
    var sessionActive = true
    var permitsRendering: Bool { windowVisible && !minimized && !occluded && !appHidden && !locked && !sleeping && sessionActive }
}

/// An override is useful for offline compositor tests; production uses OS events.
private struct DashboardVisibilityOverrideKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var dashboardVisibilityOverride: Bool? {
        get { self[DashboardVisibilityOverrideKey.self] }
        set { self[DashboardVisibilityOverrideKey.self] = newValue }
    }
}

/// Keeps observation alive while the expensive dashboard subtree is suspended.
struct DashboardVisibilityObserver: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Watcher { Watcher(changed: changed) }
    func updateNSView(_ view: Watcher, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var changed: (Bool) -> Void
        private var state = DashboardVisibilityState()
        private var observations: [(NotificationCenter, NSObjectProtocol)] = []
        private var distributed: [NSObjectProtocol] = []
        private var lastValue: Bool?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observe(.default, name, object: window) { [weak self] note in self?.refresh(closing: note.name == NSWindow.willCloseNotification) }
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observe(.default, name) { [weak self] _ in self?.refresh() }
            }
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
                observe(workspace, name) { [weak self] _ in self?.state.sleeping = true; self?.refresh() }
            }
            for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
                observe(workspace, name) { [weak self] _ in self?.state.sleeping = false; self?.refresh() }
            }
            observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.state.sessionActive = false; self?.refresh() }
            observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.state.sessionActive = true; self?.refresh() }
            // Distributed notifications cover lock/unlock even if the window's
            // occlusion notification arrives later. Initial state is queried too.
            for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
                distributed.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    self?.state.locked = locked; self?.refresh(queryLock: false)
                })
            }
            refresh()
        }
        private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil,
                             action: @escaping (Notification) -> Void) {
            observations.append((center, center.addObserver(forName: name, object: object, queue: .main, using: action)))
        }
        private func refresh(closing: Bool = false, queryLock: Bool = true) {
            state.windowVisible = !closing && window?.isVisible == true
            state.minimized = window?.isMiniaturized == true
            state.occluded = window?.occlusionState.contains(.visible) != true
            state.appHidden = NSApplication.shared.isHidden
            if queryLock, let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
                state.locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
            }
            let value = state.permitsRendering
            guard value != lastValue else { return }
            lastValue = value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastValue == value else { return }
                self.changed(value)
            }
        }
        func stop() {
            observations.forEach { $0.0.removeObserver($0.1) }; observations.removeAll()
            distributed.forEach { DistributedNotificationCenter.default().removeObserver($0) }; distributed.removeAll()
            lastValue = nil
        }
        deinit { stop() }
    }
}

/// Removal cancels animation tasks; insertion starts from the model's newest
/// snapshot, with an opacity-only transition instead of replaying old updates.
struct DashboardRenderGate<Content: View>: View {
    let visible: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        ZStack {
            DashboardTheme.background
            if visible { content().transition(.opacity) }
        }
        .animation(visible && !reduced ? .easeOut(duration: 0.22) : nil, value: visible)
    }
}
