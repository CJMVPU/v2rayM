import SwiftUI
import AppKit
import ServiceManagement
import V2rayMKit

@MainActor final class AppModel: ObservableObject {
    let dashboard = GlobeMonitor()
    @Published var homeRequest = 0
    @Published var lastStatusRefresh: Date?
    @Published var status: RuntimeStatus?
    @Published private(set) var trafficTrend = TrafficTrend()
    @Published var profiles: [Profile] = []
    @Published var logs: [LogEntry] = []
    @Published var routes: [RoutingProfile] = []
    @Published var operations: [String] = []
    @Published var moduleProgress: [ModuleUpdateProgress] = []
    @Published var moduleScope: ModuleUpdateScope?
    @Published var moduleUpdateActive = false
    @Published var moduleUpdateError: String?
    @Published var moduleTargets: [String] = ["Xray", "GeoFiles"]
    private var logBuffer = RollingLogBuffer()
    private var logCursor: Int64 = 0
    private var updateStarting = false
    private var mutationGeneration: Int { connection.revision }
    @Published var ready = false
    @Published var busy = false
    @Published var connecting = false
    @Published var systemProxyEnabled = false
    @Published var proxyNeedsRecovery = false
    @Published var tun: MacTunStatus?
    @Published var message: String?
    @Published var error: String?
    @Published private(set) var connection = ConnectionCoordinator()
    @Published private(set) var observationErrors: [String: String] = [:]
    var networkRecovery: NetworkRecovery { connection.recovery }
    var desiredMode: ProxyMode { connection.desiredMode }
    private let lifecycle: any NetworkEvents
    private let clock: any NativeClock
    private let checkTunnel: @Sendable () async throws -> Void
    private let observations: ObservationScheduler
    @Published private var pendingDisconnect = false
    private var disconnectRetryAt = Date.distantPast
    private var recoveringInFlight = false
    private var sleeping = false
    private var lastWakeAt: Date?
    private var networkAvailable = true
    private var networkObserved = false
    private var proxyRequested: Bool { connection.requested }
    private var polling: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var settingsOperation: Task<Void, Error>?
    private var shuttingDown = false
    private var api: (any NativeAPI)?
    let backend: any NativeBackend
    let proxy: any NativeProxy
    let dataDirectory: URL
    init(backend: (any NativeBackend)? = nil, proxy: (any NativeProxy)? = nil,
         clock: any NativeClock = SystemNativeClock(), network: (any NetworkEvents)? = nil,
         dataDirectory: URL? = nil, checkTunnel: @escaping @Sendable () async throws -> Void = { try await TunnelConflict.check() }) {
        let arguments = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        self.dataDirectory = dataDirectory ?? argument("--data-directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/v2rayM")
        self.backend = backend ?? BackendController(dataDirectory: self.dataDirectory, port: argument("--api-port").flatMap(Int.init) ?? 19888)
        self.proxy = proxy ?? SystemProxyController(dataDirectory: self.dataDirectory)
        self.checkTunnel = checkTunnel
        self.clock = clock; observations = ObservationScheduler(clock: clock)
        lifecycle = network ?? NetworkLifecycle()
        lifecycle.observe(sleep: { [weak self] asleep in
            guard let self else { return }
            if asleep && self.sleeping { return }
            if !asleep && !self.sleeping, let lastWakeAt = self.lastWakeAt {
                let elapsed = self.clock.now().timeIntervalSince(lastWakeAt)
                if elapsed >= 0 && elapsed < 5 { return }
            }
            self.sleeping = asleep
            if !asleep { self.lastWakeAt = self.clock.now() }
            self.beginNetworkRecovery(restart: true)
        }, change: { [weak self] available in
            guard let self else { return }
            let shouldRecover = self.networkObserved || !available
            self.networkObserved = true
            self.networkAvailable = available
            if shouldRecover { self.beginNetworkRecovery(restart: true) }
        }, resume: { [weak self] in
            guard let self else { return }
            // A visible/session wake also releases the sleep gate if macOS did
            // not deliver didWake. Plain display wake only probes health.
            let missedSystemWake = self.sleeping
            self.sleeping = false
            if missedSystemWake { self.lastWakeAt = self.clock.now() }
            self.beginNetworkRecovery(restart: missedSystemWake)
        })
    }
    func connect() async {
        guard !connecting, !ready else { return }
        connecting = true; error = nil
        defer { connecting = false }
        do {
            proxyNeedsRecovery = await proxy.needsRecovery
            if proxyNeedsRecovery { message = "检测到上次的代理设置，请点击“恢复系统代理”后继续。" }
            api = try await backend.startClient()
            logCursor = 0
            if let initial = try await api?.tunStatus() {
                tun = initial
                if initial.enabled && !initial.isRunning { try await api?.setTunEnabled(false); tun = try await api?.tunStatus() }
            }
            try await refresh()
            connection.restoreIntent(systemProxyEnabled ? .system : tun?.enabled == true ? .tun : .off)
            ready = true
            startPolling()
        } catch { self.error = error.localizedDescription; try? await backend.stop() }
    }
    private func beginNetworkRecovery(restart: Bool) {
        guard !shuttingDown, proxyRequested else { return }
        let generation = connection.recovery.generation
        connection.recovery.begin(restart: restart, now: clock.now())
        if generation != connection.recovery.generation { lastStatusRefresh = nil }
    }
    private func attemptNetworkRecovery() async throws {
        guard let api, networkRecovery.canAttempt(awake: !sleeping, networkAvailable: networkAvailable, now: clock.now()) else { return }
        let generation = networkRecovery.generation
        // Serialize recovery with user mutations and module updates.
        busy = true; recoveringInFlight = true
        defer {
            busy = false; recoveringInFlight = false
            if pendingDisconnect {
                pendingDisconnect = false
                setProxyMode(.off)
            }
        }
        try await refresh()
        operations = try await api.value("/api/operations")
        tun = try await api.freshTunStatus()
        try Task.checkCancellation()
        guard generation == networkRecovery.generation, !sleeping, networkAvailable else { return }
        guard proxyRequested else { connection.recovery.cancel(); return }
        guard !moduleUpdateActive, !RuntimeUpdateActivity.isActive(operations) else { return }
        let action = networkRecovery.action(desiredMode: desiredMode, systemProxyEnabled: systemProxyEnabled,
            tunEnabled: tun?.enabled == true, coreRunning: status?.coreRunning == true,
            runtimeState: status?.runtimeState ?? "", coreStartedAt: status?.coreStartedAt)
        let previousCoreStart = status?.coreStartedAt
        switch action {
        case .wait: return
        case .reconcileMode:
            guard !proxyNeedsRecovery else { throw ClientFailure("proxy_recovery") }
            do {
                systemProxyEnabled = try await ProxyModeSwitch.apply(desiredMode, systemProxyEnabled: systemProxyEnabled,
                    hasSelectedProfile: status?.currentProfileId?.isEmpty == false || !profiles.isEmpty,
                    backend: api, preferences: proxy, checkOtherTunnel: checkTunnel)
            } catch {
                if let failure = error as? ProxyModeFailure {
                    systemProxyEnabled = failure.systemProxyEnabled
                    proxyNeedsRecovery = await proxy.needsRecovery
                }
                throw error
            }
        case .restart:
            try await TunModeChange.checkBeforeConnecting(backend: api, checkOtherTunnel: checkTunnel)
            try Task.checkCancellation()
            guard generation == networkRecovery.generation, !sleeping, networkAvailable else { return }
            connection.recovery.submitted(startedAt: status?.coreStartedAt, generation: generation)
            if status?.runtimeState == "running" || status?.runtimeState == "faulted" {
                try await api.perform("/api/core/restart")
            } else {
                try await api.startTunCore()
            }
            connection.recovery.restarted(generation: generation)
        case .verify: break
        }
        if action == .restart || action == .reconcileMode {
            guard generation == networkRecovery.generation, !sleeping, networkAvailable else { return }
            try await refresh()
            tun = try await api.freshTunStatus()
            if action == .reconcileMode, networkRecovery.needsRestart {
                // Restoring only the system proxy preference may reuse a live
                // core. A physical network change still requires its restart.
                guard let currentCoreStart = status?.coreStartedAt, currentCoreStart != previousCoreStart else { return }
                connection.recovery.restarted(generation: generation)
            }
        }
        guard generation == networkRecovery.generation, !sleeping, networkAvailable else { return }
        guard status?.coreRunning == true,
              desiredMode == .system ? (systemProxyEnabled && tun?.enabled != true)
                : (tun?.isRunning == true && !systemProxyEnabled) else {
            throw ClientFailure("core_start_failed")
        }
        try await synchronizeProxyPort()
        connection.recovery.complete(generation: generation)
    }
    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(seconds: 2) } catch { return }
                guard let self else { return }
                await self.pollOnce()
                if !self.ready { return }
            }
        }
    }
    /// A failed observation is not a command to disconnect. Only an owned
    /// backend exit or a fresh terminal runtime state permits proxy cleanup.
    func pollOnce() async {
        guard !busy, !sleeping, !shuttingDown else { return }
        let revision = mutationGeneration, generation = networkRecovery.generation
        let backendRunning = await backend.isRunning
        guard !busy, connection.isCurrent(revision: revision, recoveryGeneration: generation) else { return }
        if !backendRunning {
            busy = true; defer { busy = false }
            connection.recovery.cancel(); observations.cancel()
            if systemProxyEnabled { try? await restoreProxy() }
            ready = false; moduleUpdateActive = false
            error = ClientFailure("backend_exited").localizedDescription
            return
        }
        if pendingDisconnect {
            if clock.now() >= disconnectRetryAt { setProxyMode(.off) }
            return
        }
        do {
            if networkRecovery.active && !moduleUpdateActive {
                if networkRecovery.canAttempt(awake: !sleeping, networkAvailable: networkAvailable, now: clock.now()) {
                    try await attemptNetworkRecovery()
                } else {
                    // Connectivity gates mutations, not diagnostics against our
                    // local backend. Keep status and logs observable offline.
                    try await refresh(forceMetadata: false)
                }
                return
            }
            try await refresh(forceMetadata: false)
            guard !busy, !sleeping, connection.isCurrent(revision: revision, recoveryGeneration: generation) else { return }
            if proxyRequested, !moduleUpdateActive, !RuntimeUpdateActivity.isActive(operations),
               status?.coreRunning == false, ["stopped", "faulted"].contains(status?.runtimeState ?? "") {
                beginNetworkRecovery(restart: true)
                return
            }
            if !moduleUpdateActive && !RuntimeUpdateActivity.isActive(operations) && systemProxyEnabled,
               let status, observationErrors["operations"] == nil {
                busy = true; defer { busy = false }
                if ConnectionCoordinator.shouldDetachSystemProxy(status), let api {
                    let active: [String] = try await api.value("/api/operations")
                    guard connection.isCurrent(revision: revision, recoveryGeneration: generation),
                          !RuntimeUpdateActivity.isActive(active) else { return }
                    try await restoreProxy()
                } else if status.coreRunning { try await synchronizeProxyPort() }
            }
        } catch {
            guard !Task.isCancelled, !busy, !sleeping,
                  connection.isCurrent(revision: revision, recoveryGeneration: generation) else { return }
            observationErrors["runtime"] = error.localizedDescription
            if moduleUpdateActive || RuntimeUpdateActivity.isActive(operations) {
                moduleUpdateError = "正在等待后台恢复，将自动重试"
            } else if NetworkRecovery.isTransient(error), proxyRequested {
                if !networkRecovery.active { beginNetworkRecovery(restart: false) }
                connection.recovery.retry(now: clock.now())
            } else if networkRecovery.active {
                connection.recovery.retry(now: clock.now())
            }
        }
    }
    @discardableResult func refresh(forceMetadata: Bool = true) async throws -> Bool {
        guard let api, !shuttingDown else { return false }
        let revision = mutationGeneration, generation = networkRecovery.generation
        if moduleUpdateActive {
            async let updates: [ModuleUpdateProgress] = api.value("/api/core-updates/progress")
            async let tasks: [String] = api.value("/api/operations")
            let snapshot = try await (updates, tasks)
            guard connection.isCurrent(revision: revision, recoveryGeneration: generation) else { return false }
            moduleProgress = snapshot.0; operations = snapshot.1; moduleUpdateError = nil
            finishModuleObservation()
            scheduleObservations(api: api, force: forceMetadata)
            return false
        }
        // Runtime publication does not await node lists, logs, helper probes,
        // routes, or update history. Their failures retain their last good data.
        let state: RuntimeStatus = try await api.value("/api/status")
        guard connection.isCurrent(revision: revision, recoveryGeneration: generation) else { return false }
        let now = clock.now()
        status = state; lastStatusRefresh = now; clearObservationError("runtime")
        trafficTrend.record(state, now: now)
        scheduleObservations(api: api, force: forceMetadata)
        return true
    }
    private func finishModuleObservation() {
        let targets = moduleScope?.targets ?? moduleTargets
        if moduleUpdateActive && !updateStarting && !RuntimeUpdateActivity.isActive(operations)
            && targets.allSatisfy({ id in moduleProgress.contains { $0.coreType == id && $0.isComplete } }) {
            moduleUpdateActive = false
        }
    }
    private func clearObservationError(_ topic: String) {
        if observationErrors[topic] != nil { observationErrors[topic] = nil }
    }
    private func scheduleObservations(api: any NativeAPI, force: Bool) {
        let revision = mutationGeneration, generation = networkRecovery.generation
        func schedule(_ topic: String, interval: Double, work: @escaping @MainActor () async throws -> Void) {
            observations.schedule(topic, interval: interval, force: force) { [weak self] in
                do { try await work() }
                catch {
                    guard let self, !Task.isCancelled,
                          self.connection.isCurrent(revision: revision, recoveryGeneration: generation) else { return }
                    self.observationErrors[topic] = error.localizedDescription
                }
            }
        }
        func current() -> Bool { !Task.isCancelled && connection.isCurrent(revision: revision, recoveryGeneration: generation) }
        schedule("logs", interval: 2) { [self] in
            let tail: LogTail = try await api.value("/api/logs/tail?after=\(logCursor)&limit=10000")
            guard current() else { return }
            if logBuffer.append(tail.items) { logs = logBuffer.entries }
            logCursor = tail.latestSequence
            clearObservationError("logs")
            if let state = status {
                let id = state.coreRunning ? state.runningProfileId : state.currentProfileId
                dashboard.update(state: state, node: profiles.first { $0.id == id }, entries: tail.items)
            }
        }
        schedule("profiles", interval: 5) { [self] in
            let value: [Profile] = try await api.value("/api/profiles?subscriptionId=")
            guard current() else { return }
            if profiles != value { profiles = value }; clearObservationError("profiles")
            if let state = status {
                let id = state.coreRunning ? state.runningProfileId : state.currentProfileId
                dashboard.update(state: state, node: profiles.first { $0.id == id }, entries: [])
            }
        }
        schedule("routes", interval: 30) { [self] in
            let value: [RoutingProfile] = try await api.value("/api/settings/routing-profiles")
            guard current() else { return }
            if routes != value { routes = value }; clearObservationError("routes")
        }
        schedule("tun", interval: 2) { [self] in
            let value = try await api.tunStatus()
            guard current() else { return }
            if tun != value { tun = value }; clearObservationError("tun")
        }
        schedule("operations", interval: 2) { [self] in
            let value: [String] = try await api.value("/api/operations")
            guard current() else { return }
            if operations != value { operations = value }; clearObservationError("operations")
        }
        schedule("updates", interval: 15) { [self] in
            let value: [ModuleUpdateProgress] = try await api.value("/api/core-updates/progress")
            guard current() else { return }
            if moduleProgress != value { moduleProgress = value }; clearObservationError("updates")
        }
    }
    func waitForObservations() async { await observations.waitUntilIdle() }
    func waitForOperation() async { await operation?.value }
    func canToggle(_ mode: ProxyMode) -> Bool {
        ready && !moduleUpdateActive && !shuttingDown && !pendingDisconnect &&
            (!busy || (recoveringInFlight && networkRecovery.active && desiredMode == mode))
    }
    func run(_ action: @escaping (any NativeAPI) async throws -> Void, success: String? = nil, finishingDisconnect: Bool = false) {
        guard ready, !busy, !moduleUpdateActive, !shuttingDown,
              !pendingDisconnect || finishingDisconnect, let api else { return }
        connection.invalidateObservations()
        busy = true; error = nil; message = nil
        operation = Task {
            defer { busy = false }
            do {
                try await action(api)
                if await observeAfterCommand() { try await synchronizeProxyPort() }
                message = success
            }
            catch {
                if let failure = error as? ProxyModeFailure {
                    self.systemProxyEnabled = failure.systemProxyEnabled
                    self.proxyNeedsRecovery = await proxy.needsRecovery
                }
                if finishingDisconnect, desiredMode == .off, NetworkRecovery.isTransient(error), error is ProxyModeFailure {
                    pendingDisconnect = true
                    disconnectRetryAt = clock.now().addingTimeInterval(2)
                    observationErrors["disconnect"] = error.localizedDescription
                    return
                }
                if networkRecovery.active && NetworkRecovery.isTransient(error) {
                    connection.recovery.retry(now: clock.now())
                    return
                }
                self.error = error.localizedDescription
                if await observeAfterCommand(), systemProxyEnabled, let status,
                   ConnectionCoordinator.shouldDetachSystemProxy(status) { try? await restoreProxy() }
            }
        }
    }
    private func observeAfterCommand() async -> Bool {
        do { return try await refresh() }
        catch { lastStatusRefresh = nil; observationErrors["runtime"] = error.localizedDescription; return false }
    }
    func displayStatus(at now: Date) -> DashboardStatus {
        DashboardStatus.resolve(ready: ready, updating: moduleUpdateActive,
            busy: busy || pendingDisconnect, recovery: proxyNeedsRecovery, state: status,
            tunRunning: tun?.isRunning == true, systemProxy: systemProxyEnabled,
            lastRefresh: lastStatusRefresh, now: now, reconnecting: networkRecovery.active)
    }
    var proxyRunning: Bool { ready && status?.coreRunning == true && (systemProxyEnabled || tun?.isRunning == true) }
    var proxyDescription: String {
        if !proxyRunning { return status?.runtimeState == "faulted" ? "代理连接失败" : "代理已关闭" }
        return (tun?.isRunning == true ? "TUN" : "系统代理") + " · " + (status?.runningProfileName ?? "已连接")
    }
    func select(_ profile: Profile) {
        run({ [self] api in
            if proxyRunning { try await TunModeChange.checkBeforeConnecting(backend: api, checkOtherTunnel: checkTunnel) }
            try await api.perform("/api/profiles/\(profile.id)/select?connect=\(proxyRunning ? "true" : "false")")
        }, success: "已选择：\(profile.remarks)")
    }
    private func setProxyMode(_ mode: ProxyMode) {
        // An in-flight restart may already have reached the backend. Invalidate
        // its generation now, then stop after it settles so it cannot win later.
        if mode == .off, recoveringInFlight, networkRecovery.active, !shuttingDown {
            connection.request(.off); pendingDisconnect = true
            return
        }
        run({ [self] api in
            if mode != .off && proxyNeedsRecovery { throw ClientFailure("proxy_recovery") }
            let previous = desiredMode
            connection.request(mode)
            if mode == .off { pendingDisconnect = false }
            do {
                systemProxyEnabled = try await ProxyModeSwitch.apply(mode, systemProxyEnabled: systemProxyEnabled,
                    hasSelectedProfile: status?.currentProfileId?.isEmpty == false || !profiles.isEmpty,
                    backend: api, preferences: proxy, checkOtherTunnel: checkTunnel)
            } catch {
                if mode != .off { connection.restoreIntent(previous) }
                throw error
            }
            clearObservationError("disconnect")
            proxyNeedsRecovery = await proxy.needsRecovery
            do { tun = try await api.tunStatus(); clearObservationError("tun") }
            catch { observationErrors["tun"] = error.localizedDescription }
        }, finishingDisconnect: mode == .off)
    }
    func toggleProxy(_ enabled: Bool) { setProxyMode(enabled ? .system : .off) }
    func toggleTun(_ enabled: Bool) { setProxyMode(enabled ? .tun : .off) }
    func authorizeTun() {
        run({ [self] api in
            let service = SMAppService.daemon(plistName: "io.github.CJMVPU.v2rayM.tun-helper.plist")
            if service.status != .enabled {
                do { try service.register() }
                catch { guard service.status == .requiresApproval else { throw error } }
            }
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw ClientFailure("tun_approval_required")
            }
            guard service.status == .enabled else { throw ClientFailure("mac_tun_helper_unavailable") }
            tun = try await api.freshTunStatus()
        }, success: "TUN 后台服务已就绪，可以开启 TUN")
    }
    func openTunApproval() { SMAppService.openSystemSettingsLoginItems() }
    func recoverProxy() {
        guard !busy, !shuttingDown else { return }
        connection.invalidateObservations()
        busy = true; error = nil
        operation = Task {
            defer { busy = false }
            do { try await restoreProxy() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func synchronizeProxyPort() async throws {
        guard systemProxyEnabled, status?.coreRunning == true, let port = status?.runningProxyPort else { return }
        do { try await proxy.rebind(port: port) }
        catch {
            systemProxyEnabled = await proxy.isEnabled
            proxyNeedsRecovery = await proxy.needsRecovery
            if !systemProxyEnabled && desiredMode == .system { connection.request(.off) }
            self.error = error.localizedDescription
            throw error
        }
    }
    func restoreProxy() async throws {
        do {
            let changed = try await proxy.restore()
            systemProxyEnabled = false; proxyNeedsRecovery = false
            if desiredMode == .system { connection.request(.off) }
            if changed { message = ClientFailure("proxy_changed").localizedDescription }
        } catch {
            systemProxyEnabled = await proxy.isEnabled
            proxyNeedsRecovery = await proxy.needsRecovery
            throw error
        }
    }
    func importNodes(_ content: String) {
        run({ api in try await api.send("/api/profiles/import", body: ImportInput(content: content)) }, success: "节点已导入")
    }
    func deleteProfile(_ item: Profile) {
        run { [self] api in
            if item.isCurrent { try await restoreProxy() }
            try await api.send("/api/profiles", method: "DELETE", body: ProfileIDs([item.id]))
        }
    }
    func updateModules(_ scope: ModuleUpdateScope) {
        guard ready, !busy, !moduleUpdateActive, !shuttingDown, !pendingDisconnect, let api else { return }
        connection.invalidateObservations()
        error = nil; message = nil
        moduleScope = scope; moduleUpdateError = nil; moduleProgress = []
        moduleUpdateActive = true; updateStarting = true
        operation = Task {
            defer { updateStarting = false }
            do {
                let settings: ModuleUpdateSettings = try await api.value("/api/core-updates")
                moduleTargets = settings.nativeTargets
                var input = settings.input
                input.useProxy = settings.useProxy && status?.coreRunning == true
                try await api.send("/api/core-updates/settings", method: "PUT", body: input)
                if let core = scope.coreType {
                    try await api.perform("/api/core-updates/\(core)/update?preRelease=true")
                } else if scope == .geo {
                    try await api.perform("/api/core/geo/update?scope=\(scope.rawValue)")
                } else {
                    try await api.send("/api/core-updates/batch", body: ["apply": true])
                }
                do { try await refresh() }
                catch { moduleUpdateError = "正在等待后台恢复，将自动重试" }
            } catch {
                moduleUpdateError = error.localizedDescription
                moduleUpdateActive = false
            }
        }
    }
    func settingsRead(_ path: String) async throws -> SettingsValue {
        guard ready, let api else { throw ClientFailure("backend_exited") }
        return try await api.value(path)
    }
    func settingsWrite(_ path: String, method: String = "PUT", body: SettingsValue? = nil) async throws {
        guard ready, !busy, !moduleUpdateActive, !shuttingDown, !pendingDisconnect, let api else { throw ClientFailure("operation_in_progress") }
        connection.invalidateObservations()
        busy = true
        defer { busy = false }
        do {
            let task = Task {
                if let body { try await api.send(path, method: method, body: body) }
                else { try await api.perform(path, method: method) }
            }
            settingsOperation = task
            defer { settingsOperation = nil }
            try await task.value
            if await observeAfterCommand() { try await synchronizeProxyPort() }
        } catch {
            if await observeAfterCommand(), systemProxyEnabled, let status,
               ConnectionCoordinator.shouldDetachSystemProxy(status) { try? await restoreProxy() }
            throw error
        }
    }
    func shutdown() async -> Bool {
        connection.invalidateObservations()
        shuttingDown = true
        connection.recovery.cancel()
        observations.cancel()
        let pendingPoll = polling
        polling?.cancel(); polling = nil
        await pendingPoll?.value
        await operation?.value
        try? await settingsOperation?.value
        defer { shuttingDown = false }
        do {
            // Never stop the listener until the system proxy has been restored successfully.
            try await restoreProxy()
            if tun?.enabled == true, let api {
                try await api.perform("/api/core/stop")
                let stopped = try await api.tunStatus()
                guard stopped.privilegedCoreProcessIds.isEmpty, stopped.runtimeState == "stopped" else {
                    throw ClientFailure("tun_stop_unconfirmed")
                }
            }
            try await backend.stop(); ready = false; api = nil
            connection.request(.off)
            return true
        } catch { self.error = error.localizedDescription; if ready { startPolling() }; return false }
    }
}
