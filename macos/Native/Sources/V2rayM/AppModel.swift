import SwiftUI
import AppKit
import ServiceManagement
import V2rayMKit

@MainActor final class AppModel: ObservableObject {
    let dashboard = GlobeMonitor()
    @Published var homeRequest = 0
    var lastStatusRefresh: Date?
    let telemetry = RuntimeTelemetry()
    var status: RuntimeStatus? {
        get { telemetry.status }
        set {
            var before = telemetry.status; before?.traffic = nil
            var after = newValue; after?.traffic = nil
            if before != after { objectWillChange.send() }
            if telemetry.status != newValue { telemetry.status = newValue }
        }
    }
    var trafficTrend: TrafficTrend { telemetry.trend }
    @Published var profiles: [Profile] = []
    let logState = LogObservation()
    var logs: [LogEntry] { get { logState.entries } set { logState.entries = newValue } }
    @Published var routes: [RoutingProfile] = []
    @Published var operations: [String] = []
    let moduleObservation = ModuleObservation()
    var moduleProgress: [ModuleUpdateProgress] {
        get { moduleObservation.progress }
        set { if moduleObservation.progress != newValue { moduleObservation.progress = newValue } }
    }
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
    private var startupOperation: Task<Void, Error>?
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
        guard !connecting, !ready, !shuttingDown else { return }
        connecting = true; error = nil
        let task = Task { try await NativeStartupService().connect(StartupAdapter(self)) }
        startupOperation = task
        defer { connecting = false; startupOperation = nil }
        do { try await task.value }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private final class StartupAdapter: NativeStartupRuntime {
        let owner: AppModel
        init(_ owner: AppModel) { self.owner = owner }
        func inspectProxyRecovery() async {
            owner.proxyNeedsRecovery = await owner.proxy.needsRecovery
            if owner.proxyNeedsRecovery { owner.message = "检测到上次的代理设置，请点击“恢复系统代理”后继续。" }
        }
        func startBackend() async throws {
            owner.api = try await owner.backend.startClient(); owner.logCursor = 0
        }
        func readTunState() async throws -> TunModeState {
            guard let api = owner.api else { throw ClientFailure("backend_exited") }
            let state = try await api.tunStatus(); owner.tun = state; return state.domainState
        }
        func disableIdleTunIntent() async throws { try await owner.api?.setTunEnabled(false) }
        func refresh() async throws { try await owner.refresh() }
        var systemProxyEnabled: Bool { owner.systemProxyEnabled }
        func restoreIntent(_ mode: ProxyMode) { owner.connection.restoreIntent(mode) }
        func connected() {
            guard !owner.shuttingDown else { return }
            owner.ready = true; owner.startPolling()
        }
        func stopAfterFailure() async { try? await owner.backend.stop(); owner.api = nil }
    }
    private func beginNetworkRecovery(restart: Bool) {
        guard !shuttingDown, proxyRequested else { return }
        let generation = connection.recovery.generation
        connection.recovery.begin(restart: restart, now: clock.now())
        if generation != connection.recovery.generation { lastStatusRefresh = nil }
    }
    private func attemptNetworkRecovery() async throws {
        guard let api, networkRecovery.canAttempt(awake: !sleeping, networkAvailable: networkAvailable, now: clock.now()) else { return }
        // Serialize recovery with user mutations and module updates.
        busy = true; recoveringInFlight = true
        defer {
            busy = false; recoveringInFlight = false
            if pendingDisconnect {
                pendingDisconnect = false
                setProxyMode(.off)
            }
        }
        switch try await NetworkRecoveryService().attempt(RecoveryAdapter(self, api: api), now: clock.now()) {
        case .waiting, .completed: break
        case .proxyRecoveryRequired: throw ClientFailure("proxy_recovery")
        case .coreStartFailed: throw ClientFailure("core_start_failed")
        }
    }
    private var recoveryObservation: RecoveryObservation {
        RecoveryObservation(awake: !sleeping, networkAvailable: networkAvailable,
            desiredMode: desiredMode, systemProxyEnabled: systemProxyEnabled,
            tunEnabled: tun?.enabled == true, tunRunning: tun?.isRunning == true,
            coreRunning: status?.coreRunning == true, runtimeState: status?.runtimeState ?? "",
            coreStartedAt: status?.coreStartedAt,
            updating: moduleUpdateActive || RuntimeUpdateActivity.isActive(operations),
            proxyNeedsRecovery: proxyNeedsRecovery)
    }
    @MainActor private final class RecoveryAdapter: NativeRecoveryRuntime {
        let owner: AppModel
        let api: any NativeAPI
        init(_ owner: AppModel, api: any NativeAPI) { self.owner = owner; self.api = api }
        var recovery: NetworkRecovery {
            get { owner.connection.recovery }
            set { owner.connection.recovery = newValue }
        }
        var observation: RecoveryObservation { owner.recoveryObservation }
        func refresh(generation: Int, includeOperations: Bool) async throws {
            try await owner.refresh()
            let operations: [String]? = includeOperations ? try await api.value("/api/operations") : nil
            let tun = try await api.freshTunStatus()
            try Task.checkCancellation()
            guard generation == recovery.generation else { return }
            if let operations { owner.operations = operations }
            owner.tun = tun
        }
        func reconcileMode() async throws {
            do {
                owner.systemProxyEnabled = try await ProxyModeSwitch.apply(owner.desiredMode, systemProxyEnabled: owner.systemProxyEnabled,
                    hasSelectedProfile: owner.status?.currentProfileId?.isEmpty == false || !owner.profiles.isEmpty,
                    backend: api, preferences: owner.proxy, checkOtherTunnel: owner.checkTunnel)
            } catch {
                if let failure = error as? ProxyModeFailure {
                    owner.systemProxyEnabled = failure.systemProxyEnabled
                    owner.proxyNeedsRecovery = await owner.proxy.needsRecovery
                }
                throw error
            }
        }
        func checkBeforeConnecting() async throws {
            try await TunModeChange.checkBeforeConnecting(backend: api, checkOtherTunnel: owner.checkTunnel)
        }
        func startOrRestartCore(restart: Bool) async throws {
            if restart { try await api.perform("/api/core/restart") }
            else { try await api.startTunCore() }
        }
        func synchronizeProxyPort() async throws { try await owner.synchronizeProxyPort() }
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
    func pollOnce() async { await NativePollingService().poll(PollingAdapter(self)) }
    @MainActor private final class PollingAdapter: NativePollingRuntime {
        let owner: AppModel
        init(_ owner: AppModel) { self.owner = owner }
        var canObserve: Bool { !owner.busy && !owner.sleeping && !owner.shuttingDown }
        var connection: ConnectionCoordinator { owner.connection }
        var observation: RecoveryObservation { owner.recoveryObservation }
        var now: Date { owner.clock.now() }
        var moduleUpdateActive: Bool { owner.moduleUpdateActive }
        var pendingDisconnect: Bool { owner.pendingDisconnect }
        var disconnectRetryDue: Bool { now >= owner.disconnectRetryAt }
        var operationsObservationValid: Bool { owner.status != nil && owner.observationErrors["operations"] == nil }
        func backendIsRunning() async -> Bool { await owner.backend.isRunning }
        func setBusy(_ busy: Bool) { owner.busy = busy }
        func cancelRecoveryAndObservations() { owner.connection.recovery.cancel(); owner.observations.cancel() }
        func publishBackendExited() {
            owner.ready = false; owner.moduleUpdateActive = false
            owner.error = ClientFailure("backend_exited").localizedDescription
        }
        func restoreSystemProxy() async throws { try await owner.restoreProxy() }
        func retryDisconnect() { owner.setProxyMode(.off) }
        func attemptRecovery() async throws { try await owner.attemptNetworkRecovery() }
        func refresh() async throws { try await owner.refresh(forceMetadata: false) }
        func freshUpdateActivity() async throws -> Bool {
            guard let api = owner.api else { return true }
            let active: [String] = try await api.value("/api/operations")
            return RuntimeUpdateActivity.isActive(active)
        }
        func synchronizeProxyPort() async throws { try await owner.synchronizeProxyPort() }
        func beginRecovery(restart: Bool) { owner.beginNetworkRecovery(restart: restart) }
        func retryRecovery() { owner.connection.recovery.retry(now: now) }
        func reportObservationFailure(_ error: Error) { owner.observationErrors["runtime"] = error.localizedDescription }
        func reportUpdateWaiting() { owner.moduleUpdateError = "正在等待后台恢复，将自动重试" }
        func isTransient(_ error: Error) -> Bool { NetworkRecovery.isTransient(error) }
    }
    @discardableResult func refresh(forceMetadata: Bool = true) async throws -> Bool {
        guard let api, !shuttingDown else { return false }
        let revision = mutationGeneration, generation = networkRecovery.generation
        if moduleUpdateActive {
            async let updates: [ModuleUpdateProgress] = api.value("/api/core-updates/progress")
            async let tasks: [String] = api.value("/api/operations")
            let snapshot = try await (updates, tasks)
            guard connection.isCurrent(revision: revision, recoveryGeneration: generation) else { return false }
            moduleProgress = snapshot.0
            if operations != snapshot.1 { operations = snapshot.1 }
            if moduleUpdateError != nil { moduleUpdateError = nil }
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
        telemetry.record(state, now: now)
        scheduleObservations(api: api, force: forceMetadata)
        return true
    }
    private func finishModuleObservation() {
        let targets = moduleScope?.targets ?? moduleTargets
        if moduleUpdateActive && NativeModuleUpdateCompletion.finished(starting: updateStarting,
            operations: operations, targets: targets, terminalTargets: Set(moduleProgress.filter(\.isComplete).map(\.coreType))) {
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
                let result = try await NativeCommandService().execute({ try await action(api) },
                    runtime: CommandAdapter(self), finishingDisconnect: finishingDisconnect)
                if result == .completed { message = success }
            } catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private final class CommandAdapter: NativeCommandRuntime {
        let owner: AppModel
        init(_ owner: AppModel) { self.owner = owner }
        func observe() async -> Bool { await owner.observeAfterCommand() }
        func synchronizeProxyPort() async throws { try await owner.synchronizeProxyPort() }
        func reconcileFailure(_ error: Error) async {
            if let failure = error as? ProxyModeFailure {
                owner.systemProxyEnabled = failure.systemProxyEnabled
                owner.proxyNeedsRecovery = await owner.proxy.needsRecovery
            }
        }
        func disposition(_ error: Error, finishingDisconnect: Bool) -> CommandFailureDisposition {
            CommandFailurePolicy.resolve(finishingDisconnect: finishingDisconnect, desiredMode: owner.desiredMode,
                transient: NetworkRecovery.isTransient(error), modeSwitchFailure: error is ProxyModeFailure,
                recoveryActive: owner.networkRecovery.active)
        }
        func scheduleRetry(_ disposition: CommandFailureDisposition, error: Error) {
            switch disposition {
            case .retryDisconnect:
                owner.pendingDisconnect = true
                owner.disconnectRetryAt = owner.clock.now().addingTimeInterval(2)
                owner.observationErrors["disconnect"] = error.localizedDescription
            case .retryRecovery: owner.connection.recovery.retry(now: owner.clock.now())
            case .report: break
            }
        }
        var shouldDetachSystemProxy: Bool {
            owner.systemProxyEnabled && owner.status.map(ConnectionCoordinator.shouldDetachSystemProxy) == true
        }
        func restoreSystemProxy() async throws { try await owner.restoreProxy() }
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
                try await NativeModuleUpdateService().submit(scope, runtime: ModuleUpdateAdapter(self, api: api))
                do { try await refresh() }
                catch { moduleUpdateError = "正在等待后台恢复，将自动重试" }
            } catch {
                moduleUpdateError = error.localizedDescription
                moduleUpdateActive = false
            }
        }
    }
    @MainActor private final class ModuleUpdateAdapter: NativeModuleUpdateRuntime {
        let owner: AppModel
        let api: any NativeAPI
        init(_ owner: AppModel, api: any NativeAPI) { self.owner = owner; self.api = api }
        var coreRunning: Bool { owner.status?.coreRunning == true }
        func loadPlan() async throws -> NativeModuleUpdatePlan {
            let settings: ModuleUpdateSettings = try await api.value("/api/core-updates")
            owner.moduleTargets = settings.nativeTargets
            return settings.plan
        }
        func savePreferences(_ plan: NativeModuleUpdatePlan) async throws {
            try await api.send("/api/core-updates/settings", method: "PUT", body: ModuleUpdateSettings.Input(plan))
        }
        func submit(_ scope: ModuleUpdateScope) async throws {
            if let core = scope.coreType {
                try await api.perform("/api/core-updates/\(core)/update?preRelease=true")
            } else if scope == .geo {
                try await api.perform("/api/core/geo/update?scope=\(scope.rawValue)")
            } else {
                try await api.send("/api/core-updates/batch", body: ["apply": true])
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
        let task = Task {
            _ = try await NativeCommandService().execute({
                if let body { try await api.send(path, method: method, body: body) }
                else { try await api.perform(path, method: method) }
            }, runtime: CommandAdapter(self), allowDeferredRetry: false)
        }
        settingsOperation = task
        defer { settingsOperation = nil }
        try await task.value
    }
    func shutdown() async -> Bool {
        defer { shuttingDown = false }
        do {
            guard try await NativeShutdownService().shutdown(ShutdownAdapter(self)) == .stopped else {
                throw ClientFailure("tun_stop_unconfirmed")
            }
            ready = false; api = nil
            connection.request(.off)
            return true
        } catch { self.error = error.localizedDescription; if ready { startPolling() }; return false }
    }
    @MainActor private final class ShutdownAdapter: NativeShutdownRuntime {
        let owner: AppModel
        var pendingPoll: Task<Void, Never>?
        init(_ owner: AppModel) { self.owner = owner }
        func quiesce() {
            owner.connection.invalidateObservations()
            owner.shuttingDown = true
            owner.connection.recovery.cancel()
            owner.observations.cancel()
            pendingPoll = owner.polling
            owner.polling?.cancel(); owner.polling = nil
        }
        func drainPendingWork() async {
            try? await owner.startupOperation?.value
            await pendingPoll?.value
            await owner.operation?.value
            try? await owner.settingsOperation?.value
            await owner.observations.waitUntilIdle()
        }
        func restoreSystemProxy() async throws { try await owner.restoreProxy() }
        var requiresTunnelStop: Bool { owner.tun?.enabled == true }
        func stopTunnel() async throws -> TunnelStopEvidence {
            guard let api = owner.api else { throw ClientFailure("backend_exited") }
            try await api.perform("/api/core/stop")
            let stopped = try await api.freshTunStatus()
            return TunnelStopEvidence(ownedProcessIDs: stopped.privilegedCoreProcessIds, runtimeState: stopped.runtimeState)
        }
        func stopOwnedBackend() async throws { try await owner.backend.stop() }
    }
}
