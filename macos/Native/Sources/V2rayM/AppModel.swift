import SwiftUI
import AppKit
import V2rayMKit

@MainActor final class AppModel: ObservableObject {
    @Published var status: RuntimeStatus?
    @Published var profiles: [Profile] = []
    @Published var subscriptions: [Subscription] = []
    @Published var logs: [LogEntry] = []
    @Published var routes: [RoutingProfile] = []
    @Published var operations: [String] = []
    @Published var ready = false
    @Published var busy = false
    @Published var connecting = false
    @Published var systemProxyEnabled = false
    @Published var proxyNeedsRecovery = false
    @Published var message: String?
    @Published var error: String?
    @Published var search = ""
    @Published var subscriptionFilter = ""
    private var polling: Task<Void, Never>?
    private var operation: Task<Void, Never>?
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
    var filteredProfiles: [Profile] {
        profiles.filter { (subscriptionFilter.isEmpty || $0.subscriptionId == subscriptionFilter)
            && (search.isEmpty || ($0.remarks + $0.address + ($0.subscriptionName ?? "")).localizedCaseInsensitiveContains(search)) }
    }
    func connect() async {
        guard !connecting, !ready else { return }
        connecting = true; error = nil
        defer { connecting = false }
        do {
            proxyNeedsRecovery = await proxy.needsRecovery
            if proxyNeedsRecovery { message = "检测到上次的代理设置，请点击“恢复系统代理”后继续。" }
            api = try await backend.start()
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
                    if self.systemProxyEnabled && self.status?.coreRunning != true { try await self.restoreProxy() }
                } catch {
                    guard !Task.isCancelled else { return }
                    if self.systemProxyEnabled { try? await self.restoreProxy() }
                    self.error = error.localizedDescription
                    if !(await self.backend.isRunning) { self.ready = false; return }
                }
            }
        }
    }
    func refresh() async throws {
        guard let api else { return }
        // Publish a coherent snapshot; a failed refresh never replaces the last good list with empty data.
        async let state: RuntimeStatus = api.value("/api/status")
        async let nodes: [Profile] = api.value("/api/profiles?subscriptionId=")
        async let groups: [Subscription] = api.value("/api/subscriptions")
        async let recent: [LogEntry] = api.value("/api/logs?limit=120")
        async let routing: [RoutingProfile] = api.value("/api/settings/routing-profiles")
        async let tasks: [String] = api.value("/api/operations")
        let snapshot = try await (state, nodes, groups, recent, routing, tasks)
        status = snapshot.0; profiles = snapshot.1; subscriptions = snapshot.2; logs = snapshot.3
        routes = snapshot.4; operations = snapshot.5
        if !subscriptionFilter.isEmpty && !subscriptions.contains(where: { $0.id == subscriptionFilter }) { subscriptionFilter = "" }
    }
    func run(_ action: @escaping (APIClient) async throws -> Void, success: String? = nil) {
        guard ready, !busy, !shuttingDown, let api else { return }
        busy = true; error = nil; message = nil
        operation = Task {
            defer { busy = false }
            do { try await action(api); try await refresh(); message = success }
            catch {
                self.error = error.localizedDescription
                try? await refresh()
                if systemProxyEnabled && status?.coreRunning != true { try? await restoreProxy() }
            }
        }
    }
    func select(_ profile: Profile) {
        run({ api in try await api.perform("/api/profiles/\(profile.id)/select") }, success: "已连接：\(profile.remarks)")
    }
    func toggleCore() {
        guard !busy else { return }
        let running = status?.coreRunning == true
        run { [self] api in
            if running { try await restoreProxy() }
            try await api.perform(running ? "/api/core/stop" : "/api/core/start")
        }
    }
    func toggleProxy(_ enabled: Bool) {
        run { [self] api in
            if enabled {
                guard !proxyNeedsRecovery else { throw ClientFailure("proxy_recovery") }
                if status?.coreRunning != true { try await api.perform("/api/core/start") }
                let running: RuntimeStatus = try await api.value("/api/status")
                guard running.coreRunning, let port = running.runningProxyPort else { throw ClientFailure("core_start_failed") }
                do { try await proxy.enable(port: port); systemProxyEnabled = true }
                catch { proxyNeedsRecovery = await proxy.needsRecovery; throw error }
            } else { try await restoreProxy() }
        }
    }
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
    func importNodes(_ content: String, subscription: String) {
        run({ api in try await api.send("/api/profiles/import", body: ImportInput(content: content, subscriptionId: subscription)) }, success: "节点已导入")
    }
    func saveSubscription(name: String, url: String, enabled: Bool, existing: Subscription?) {
        let input = SubscriptionInput(name: name, url: url, enabled: enabled, existing: existing)
        run({ api in try await api.send(existing.map { "/api/subscriptions/\($0.id)" } ?? "/api/subscriptions",
                                     method: existing == nil ? "POST" : "PUT", body: input) }, success: "订阅已保存，点击更新获取节点")
    }
    func updateSubscription(_ id: String? = nil) {
        let path = id.map { "/api/subscriptions/\($0)/update?useProxy=false" } ?? "/api/subscriptions/update"
        run({ api in
            if id == nil { try await api.send(path, body: ["useProxy": false]) }
            else { try await api.perform(path) }
        }, success: "订阅正在更新，列表会自动刷新")
    }
    func deleteSubscription(_ item: Subscription) {
        run { [self] api in
            if profiles.contains(where: { $0.subscriptionId == item.id && $0.isCurrent }) { try await restoreProxy() }
            try await api.perform("/api/subscriptions/\(item.id)", method: "DELETE")
        }
    }
    func deleteProfile(_ item: Profile) {
        run { [self] api in
            if item.isCurrent { try await restoreProxy() }
            try await api.send("/api/profiles", method: "DELETE", body: ProfileIDs([item.id]))
        }
    }
    func installXray() {
        run({ api in try await api.perform("/api/core-updates/Xray/update?preRelease=false&useProxy=false") }, success: "正在下载 Xray，完成后可连接节点")
    }
    func shutdown() async -> Bool {
        shuttingDown = true
        polling?.cancel(); polling = nil
        await operation?.value
        defer { shuttingDown = false }
        do {
            // Never stop the listener until the system proxy has been restored successfully.
            try await restoreProxy()
            try await backend.stop(); ready = false; api = nil
            return true
        } catch { self.error = error.localizedDescription; if ready { startPolling() }; return false }
    }
}
