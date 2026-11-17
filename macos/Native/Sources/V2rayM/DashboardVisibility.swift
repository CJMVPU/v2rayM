import AppKit
import SwiftUI
import CoreGraphics

struct DashboardVisibilityState: Equatable {
    var windowVisible = false
    var minimized = false
    var minimizing = false
    var surfaceRevision = 0
    var occluded = true
    var appHidden = false
    var appActive = true
    var locked = false
    var sleeping = false
    var sessionActive = true
    var requiresImmediatePause: Bool { !windowVisible || minimized || minimizing || appHidden || locked || sleeping || !sessionActive }
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
    var rendering = true
    let changed: (DashboardVisibilityState) -> Void
    func makeNSView(context: Context) -> Watcher { Watcher(changed: changed) }
    func updateNSView(_ view: Watcher, context: Context) {
        view.changed = changed
        if rendering { view.thaw() }
    }
    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var changed: (DashboardVisibilityState) -> Void
        private var state = DashboardVisibilityState()
        private var observations: [(NotificationCenter, NSObjectProtocol)] = []
        private var distributed: [NSObjectProtocol] = []
        private var lastValue: DashboardVisibilityState?
        private var resigning = false
        private var hiding = false
        init(changed: @escaping (DashboardVisibilityState) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            for name in [NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observe(.default, name, object: window) { [weak self] note in
                    guard let self else { return }
                    if note.name == NSWindow.willMiniaturizeNotification { self.state.minimizing = true }
                    if note.name == NSWindow.didMiniaturizeNotification || note.name == NSWindow.didDeminiaturizeNotification {
                        self.state.minimizing = false
                    }
                    self.state.surfaceRevision += 1
                    self.refresh(closing: note.name == NSWindow.willCloseNotification, synchronous: true)
                }
            }
            for name in [NSApplication.willHideNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                         NSApplication.willResignActiveNotification, NSApplication.didBecomeActiveNotification,
                         NSApplication.didResignActiveNotification] {
                observe(.default, name) { [weak self] note in
                    guard let self else { return }
                    if note.name == NSApplication.willResignActiveNotification { self.resigning = true }
                    if note.name == NSApplication.didBecomeActiveNotification { self.resigning = false }
                    if note.name == NSApplication.willHideNotification { self.hiding = true }
                    if note.name == NSApplication.didUnhideNotification { self.hiding = false }
                    self.refresh(synchronous: true)
                }
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
        private func refresh(closing: Bool = false, queryLock: Bool = true, synchronous: Bool = false) {
            state.windowVisible = !closing && window?.isVisible == true
            state.minimized = window?.isMiniaturized == true
            state.occluded = window?.occlusionState.contains(.visible) != true
            state.appHidden = hiding || NSApplication.shared.isHidden
            state.appActive = !resigning && NSApplication.shared.isActive
            if queryLock, let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
                state.locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
            }
            let value = state
            guard value != lastValue else { return }
            lastValue = value
            if !value.permitsRendering {
                NotificationCenter.default.post(name: .dashboardWillFreeze, object: window)
            }
            // Early AppKit notifications must stop publication in this same turn.
            // Only initial attachment is deferred to avoid mutating a view update.
            if synchronous { changed(value); return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastValue == value else { return }
                self.changed(value)
            }
        }
        func thaw() {
            guard state.permitsRendering, let window else { return }
            NotificationCenter.default.post(name: .dashboardDidThaw, object: window)
        }
        func stop() {
            observations.forEach { $0.0.removeObserver($0.1) }; observations.removeAll()
            distributed.forEach { DistributedNotificationCenter.default().removeObserver($0) }; distributed.removeAll()
            lastValue = nil; resigning = false; hiding = false; state.minimizing = false
        }
        deinit { stop() }
    }
}

/// Stage Manager thumbnails can remain unoccluded. Observe foreground activity
/// as well; neither event is a transition-completion signal. Keep the
/// existing surface frozen until return has remained stable; never remove its tree.
enum DashboardPresentationPhase: Equatable {
    case live, suspended, returning, catchingUp
    var rendersMotion: Bool { self == .live || self == .catchingUp }
    var acceptsData: Bool { self == .live || self == .catchingUp }
    var permitsFlips: Bool { self == .live }
}

@MainActor final class DashboardVisibilityCoordinator: ObservableObject {
    var phaseChanged: ((DashboardPresentationPhase) -> Void)?
    @Published private(set) var phase: DashboardPresentationPhase = .suspended {
        didSet { if phase != oldValue { phaseChanged?(phase) } }
    }
    private var worker: Task<Void, Never>?
    private var lastState: DashboardVisibilityState?
    private var hasPresented = false
    let returnDelay: TimeInterval
    let catchUpDuration: TimeInterval
    init(returnDelay: TimeInterval = 0.85, catchUpDuration: TimeInterval = 0.45) {
        self.returnDelay = returnDelay; self.catchUpDuration = catchUpDuration
    }
    func update(_ state: DashboardVisibilityState) {
        guard state != lastState else { return }
        let wasVisible = lastState?.permitsRendering == true
        lastState = state
        if wasVisible && state.permitsRendering && phase == .live { return }
        worker?.cancel(); worker = nil
        if !state.permitsRendering {
            phase = .suspended
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

extension Notification.Name {
    static let dashboardDidThaw = Notification.Name("v2rayM.dashboardDidThaw")
    static let dashboardWillFreeze = Notification.Name("v2rayM.dashboardWillFreeze")
}
