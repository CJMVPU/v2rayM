import SwiftUI
import AppKit
import ServiceManagement
import V2rayMKit

@MainActor final class AppModel: ObservableObject {
    @Published var lastStatusRefresh: Date?
    @Published var status: RuntimeStatus?
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
    private var updateGeneration = 0
    @Published var ready = false
    @Published var busy = false
    @Published var connecting = false
    @Published var systemProxyEnabled = false
    @Published var proxyNeedsRecovery = false
    @Published var tun: MacTunStatus?
    @Published var message: String?
    @Published var error: String?
    private var polling: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var settingsOperation: Task<Void, Error>?
    private var shuttingDown = false
    private var api: APIClient?
    let backend: BackendController
    let proxy: SystemProxyController
    let dataDirectory: URL
    init() {
        let arguments = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        dataDirectory = argument("--data-directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/v2rayM")
        backend = BackendController(dataDirectory: dataDirectory, port: argument("--api-port").flatMap(Int.init) ?? 19888)
        proxy = SystemProxyController(dataDirectory: dataDirectory)
    }
    func connect() async {
        guard !connecting, !ready else { return }
        connecting = true; error = nil
        defer { connecting = false }
        do {
            proxyNeedsRecovery = await proxy.needsRecovery
            if proxyNeedsRecovery { message = "检测到上次的代理设置，请点击“恢复系统代理”后继续。" }
            api = try await backend.start()
            logCursor = 0
            if let initial = try await api?.tunStatus(), initial.enabled && !initial.isRunning {
                try await api?.setTunEnabled(false)
            }
            try await refresh()
            ready = true
            startPolling()
        } catch { self.error = error.localizedDescription; try? await backend.stop() }
    }
    private func startPolling() {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                guard !self.busy else { continue }
                do {
                    guard await self.backend.isRunning else { throw ClientFailure("backend_exited") }
                    try await self.refresh()
                    if !self.moduleUpdateActive && !RuntimeUpdateActivity.isActive(self.operations)
                        && self.systemProxyEnabled && self.status?.coreRunning != true { try await self.restoreProxy() }
                } catch {
                    guard !Task.isCancelled else { return }
                    if await self.backend.isRunning, self.moduleUpdateActive || RuntimeUpdateActivity.isActive(self.operations) {
                        self.moduleUpdateError = "进度暂时无法刷新，将自动重试：" + error.localizedDescription
                        continue
                    }
                    if self.systemProxyEnabled { try? await self.restoreProxy() }
                    self.error = error.localizedDescription
                    if !(await self.backend.isRunning) { self.ready = false; self.moduleUpdateActive = false; return }
                }
            }
        }
    }
    func refresh() async throws {
        guard let api else { return }
        let tail: LogTail = try await api.value("/api/logs/tail?after=\(logCursor)&limit=10000")
        logBuffer.append(tail.items); logCursor = tail.latestSequence; logs = logBuffer.entries
        let observedGeneration = updateGeneration
        let observesStartedRun = !updateStarting
        if moduleUpdateActive {
            // Updating rules or checking the helper can temporarily block other runtime
            // reads. Poll the independent progress endpoints so the bars keep moving.
            async let updates: [ModuleUpdateProgress] = api.value("/api/core-updates/progress")
            async let tasks: [String] = api.value("/api/operations")
            let snapshot = try await (updates, tasks)
            guard observedGeneration == updateGeneration else { return }
            moduleProgress = snapshot.0; operations = snapshot.1; moduleUpdateError = nil
            let targets = moduleScope?.targets ?? moduleTargets
            if observesStartedRun && !updateStarting
                && !operations.contains(where: { $0.hasPrefix("core-update") || $0 == "geo-update" })
                && targets.allSatisfy({ id in moduleProgress.contains(where: { $0.coreType == id && $0.isComplete }) }) {
                moduleUpdateActive = false
            }
            return
        }
        // Publish a coherent snapshot; a failed refresh never replaces the last good list with empty data.
        async let state: RuntimeStatus = api.value("/api/status")
        async let nodes: [Profile] = api.value("/api/profiles?subscriptionId=")
        async let routing: [RoutingProfile] = api.value("/api/settings/routing-profiles")
        async let tasks: [String] = api.value("/api/operations")
        async let updates: [ModuleUpdateProgress] = api.value("/api/core-updates/progress")
        async let tunnel: MacTunStatus = api.tunStatus()
        let snapshot = try await (state, nodes, routing, tasks, tunnel, updates)
        status = snapshot.0; profiles = snapshot.1; lastStatusRefresh = Date()
        routes = snapshot.2; operations = snapshot.3
        tun = snapshot.4
        if observedGeneration == updateGeneration {
            moduleProgress = snapshot.5
            let targets = moduleScope?.targets ?? moduleTargets
            if moduleUpdateActive && observesStartedRun && !updateStarting
                && !operations.contains(where: { $0.hasPrefix("core-update") || $0 == "geo-update" })
                && targets.allSatisfy({ id in moduleProgress.contains(where: { $0.coreType == id && $0.isComplete }) }) {
                moduleUpdateActive = false
            }
        }
    }
    func run(_ action: @escaping (APIClient) async throws -> Void, success: String? = nil) {
        guard ready, !busy, !moduleUpdateActive, !shuttingDown, let api else { return }
        busy = true; error = nil; message = nil
        operation = Task {
            defer { busy = false }
            do { try await action(api); try await refresh(); message = success }
            catch {
                if let failure = error as? ProxyModeFailure {
                    self.systemProxyEnabled = failure.systemProxyEnabled
                    self.proxyNeedsRecovery = await proxy.needsRecovery
                }
                self.error = error.localizedDescription
                try? await refresh()
                if systemProxyEnabled && status?.coreRunning != true { try? await restoreProxy() }
            }
        }
    }
    var proxyRunning: Bool { ready && status?.coreRunning == true && (systemProxyEnabled || tun?.isRunning == true) }
    var proxyDescription: String {
        if !proxyRunning { return status?.runtimeState == "faulted" ? "代理连接失败" : "代理已关闭" }
        return (tun?.isRunning == true ? "TUN" : "系统代理") + " · " + (status?.runningProfileName ?? "已连接")
    }
    func select(_ profile: Profile) {
        run({ [self] api in
            if proxyRunning { try await TunModeChange.checkBeforeConnecting(backend: api) }
            try await api.perform("/api/profiles/\(profile.id)/select?connect=\(proxyRunning ? "true" : "false")")
        }, success: "已选择：\(profile.remarks)")
    }
    private func setProxyMode(_ mode: ProxyMode) {
        run { [self] api in
            if mode != .off && proxyNeedsRecovery { throw ClientFailure("proxy_recovery") }
            systemProxyEnabled = try await ProxyModeSwitch.apply(mode, systemProxyEnabled: systemProxyEnabled,
                hasSelectedProfile: status?.currentProfileId?.isEmpty == false || !profiles.isEmpty,
                backend: api, preferences: proxy)
            proxyNeedsRecovery = await proxy.needsRecovery
        }
    }
    func toggleProxy(_ enabled: Bool) { setProxyMode(enabled ? .system : .off) }
    func toggleTun(_ enabled: Bool) { setProxyMode(enabled ? .tun : .off) }
    func authorizeTun() {
        run({ _ in
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
        }, success: "TUN 后台服务已就绪，可以开启 TUN")
    }
    func openTunApproval() { SMAppService.openSystemSettingsLoginItems() }
    func recoverProxy() {
        guard !busy, !shuttingDown else { return }
        busy = true; error = nil
        operation = Task {
            defer { busy = false }
            do { try await restoreProxy() }
            catch { self.error = error.localizedDescription }
        }
    }
    func restoreProxy() async throws {
        let changed = try await proxy.restore()
        systemProxyEnabled = false; proxyNeedsRecovery = false
        if changed { message = ClientFailure("proxy_changed").localizedDescription }
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
        guard ready, !busy, !moduleUpdateActive, !shuttingDown, let api else { return }
        error = nil; message = nil
        moduleScope = scope; moduleUpdateError = nil; moduleProgress = []
        moduleUpdateActive = true; updateStarting = true; updateGeneration += 1
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
                try await refresh()
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
        guard ready, !busy, !moduleUpdateActive, !shuttingDown, let api else { throw ClientFailure("operation_in_progress") }
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
            try await refresh()
        } catch {
            try? await refresh()
            if systemProxyEnabled && status?.coreRunning != true { try? await restoreProxy() }
            throw error
        }
    }
    func shutdown() async -> Bool {
        shuttingDown = true
        polling?.cancel(); polling = nil
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
            return true
        } catch { self.error = error.localizedDescription; if ready { startPolling() }; return false }
    }
}
