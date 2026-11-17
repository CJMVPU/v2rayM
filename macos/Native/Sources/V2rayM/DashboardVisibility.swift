import AppKit
import SwiftUI
import CoreGraphics

struct DashboardVisibilityState: Equatable {
    var windowVisible = false
    var minimized = false
    var occluded = true
    var appHidden = false
    var appActive = true
    var locked = false
    var sleeping = false
    var sessionActive = true
    var requiresImmediatePause: Bool { !windowVisible || minimized || appHidden || locked || sleeping || !sessionActive }
    var permitsRendering: Bool { !requiresImmediatePause && !occluded && appActive }
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
    let changed: (DashboardVisibilityState) -> Void
    func makeNSView(context: Context) -> Watcher { Watcher(changed: changed) }
    func updateNSView(_ view: Watcher, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var changed: (DashboardVisibilityState) -> Void
        private var state = DashboardVisibilityState()
        private var observations: [(NotificationCenter, NSObjectProtocol)] = []
        private var distributed: [NSObjectProtocol] = []
        private var lastValue: DashboardVisibilityState?
        init(changed: @escaping (DashboardVisibilityState) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observe(.default, name, object: window) { [weak self] note in self?.refresh(closing: note.name == NSWindow.willCloseNotification) }
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
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
            state.appActive = NSApplication.shared.isActive
            if queryLock, let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
                state.locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
            }
            let value = state
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

/// Stage Manager thumbnails can remain unoccluded. Observe foreground activity
/// as well; neither event is a transition-completion signal. Keep the
/// existing surface through a quiet interval; never remove its content tree.
enum DashboardPresentationPhase: Equatable {
    case live, departing, suspended, returning, catchingUp
    var rendersMotion: Bool { self == .live || self == .departing || self == .catchingUp }
    var acceptsData: Bool { self == .live || self == .catchingUp }
    var permitsFlips: Bool { self == .live || self == .departing || self == .returning }
}

@MainActor final class DashboardVisibilityCoordinator: ObservableObject {
    @Published private(set) var phase: DashboardPresentationPhase = .suspended
    private var worker: Task<Void, Never>?
    private var lastState: DashboardVisibilityState?
    private var hasPresented = false
    let departureDelay: TimeInterval
    let returnDelay: TimeInterval
    let catchUpDuration: TimeInterval
    init(departureDelay: TimeInterval = 1.0, returnDelay: TimeInterval = 0.65, catchUpDuration: TimeInterval = 0.45) {
        self.departureDelay = departureDelay; self.returnDelay = returnDelay; self.catchUpDuration = catchUpDuration
    }
    func update(_ state: DashboardVisibilityState) {
        guard state != lastState else { return }
        lastState = state
        worker?.cancel(); worker = nil
        if state.requiresImmediatePause { phase = .suspended; return }
        if state.occluded || !state.appActive {
            guard phase != .suspended else { return }
            phase = .departing
            worker = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(self.departureDelay)) } catch { return }
                guard !Task.isCancelled else { return }
                self.phase = .suspended
            }
        } else if !hasPresented {
            hasPresented = true; phase = .live
        } else {
            phase = .returning
            worker = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(self.returnDelay)) } catch { return }
                guard !Task.isCancelled else { return }
                self.phase = .catchingUp
                do { try await Task.sleep(for: .seconds(self.catchUpDuration)) } catch { return }
                guard !Task.isCancelled else { return }
                self.phase = .live
            }
        }
    }
    func stop() { worker?.cancel(); worker = nil; lastState = nil; phase = .suspended }
    deinit { worker?.cancel() }
}

private struct DashboardMotionEnabledKey: EnvironmentKey { static let defaultValue = true }
private struct DashboardFlipsEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var dashboardMotionEnabled: Bool {
        get { self[DashboardMotionEnabledKey.self] }
        set { self[DashboardMotionEnabledKey.self] = newValue }
    }
    var dashboardFlipsEnabled: Bool {
        get { self[DashboardFlipsEnabledKey.self] }
        set { self[DashboardFlipsEnabledKey.self] = newValue }
    }
}
