import Foundation
import Darwin
import ServiceManagement
import TunShared
import V2rayMApplication
import V2rayMDomain

/// The application owns its SQLite store, runtime state and forwarding engine directly.
/// The data-directory lock is shared with older releases during an upgrade or rollback.
public actor NativeRuntimeHost: NativeBackend, NativeAPI {
    let store: NativeConfigurationStore
    private let bundle: URL
    private var embedded: EmbeddedXray?
    private var bundledXrayVersion: String?
    private var cleanupPending = false

    private func loadEmbedded() throws -> EmbeddedXray {
        if let embedded { return embedded }
        do {
            let library = try EmbeddedXray(bundle: bundle)
            embedded = library
            return library
        } catch {
            bundledXrayVersion = nil
            throw error
        }
    }

    private func collectCoreLogs() async {
        guard let embedded else { return }
        let lines = await embedded.drainLogs()
        history.append(source: "core", lines: lines)
    }

    let helper: NativeHelperSession
    let history = NativeRuntimeLog()
    let dataDirectory: URL
    private var geoAssets: NativeGeoAssets { NativeGeoAssets(dataDirectory: dataDirectory, bundled: assets) }
    let assets: URL
    private let presetSources: [String: RegionalSources]
    private var regionTask: Task<Void, Error>?
    private let automaticMaintenance: Bool
    private var maintenance: Task<Void, Never>?
    private var subscriptionRetry = [String: Date]()
    private let checkTunnelConflict: @Sendable () async throws -> Void
    private let mayContactHelper: Bool
    private var lockFile: Int32 = -1
    private var initialized = false
    private var closing = false
    private var geoTransferID: UUID?
    private var updateTask: Task<Void, Never>?
    private var latestGeoProgress: ModuleUpdateProgress?
    private var speedTest: Task<Void, Never>?
    private var subscriptionUpdate: Task<Void, Never>?
    private var geoActivationSignal: AsyncStream<Void>.Continuation?
    private var operation: String? {
        didSet { if operation == nil { geoActivationSignal?.yield(()) } }
    }
    private var serving: (id: String, name: String, endpoints: ProxyEndpoints?, pid: Int32, tun: Bool, started: String, sessionID: UUID)?
    private var trafficSampler: NativeTrafficSampler?
    private var failure: String?
    private var helperObservation = TunSessionObservation()

    private var currentTunID: UUID? { serving.flatMap { $0.tun ? $0.sessionID : nil } }
    private var runtimeFailure: String? { failure ?? helperObservation.failure(for: currentTunID) }
    private var runtimeState: String { runtimeFailure != nil ? "faulted" : serving == nil ? "stopped" : "running" }
    public var isRunning: Bool { initialized }

    public init(bundle: URL = Bundle.main.bundleURL, dataDirectory: URL, mayContactHelper: Bool = true, automaticMaintenance: Bool = true,
                presetSources: [String: RegionalSources] = [:]) {
        self.init(bundle: bundle, dataDirectory: dataDirectory, mayContactHelper: mayContactHelper,
                  automaticMaintenance: automaticMaintenance, presetSources: presetSources, helper: NativeHelperSession())
    }

    init(bundle: URL = Bundle.main.bundleURL, dataDirectory: URL, mayContactHelper: Bool = true, automaticMaintenance: Bool = false,
         presetSources: [String: RegionalSources] = [:], helper: NativeHelperSession,
         checkTunnelConflict: @escaping @Sendable () async throws -> Void = { try await TunnelConflict.check() }) {
        self.bundle = bundle
        bundledXrayVersion = EmbeddedXray.bundledVersion(in: bundle)
        self.presetSources = presetSources
        self.automaticMaintenance = automaticMaintenance
        self.dataDirectory = dataDirectory
        self.mayContactHelper = mayContactHelper
        assets = bundle.appendingPathComponent("Contents/Resources/Backend/bin", isDirectory: true)
        store = NativeConfigurationStore(dataDirectory: dataDirectory)
        self.helper = helper
        self.checkTunnelConflict = checkTunnelConflict
    }

    public func startClient() async throws -> any NativeAPI {
        try await start()
        return self
    }

    public func start() async throws {
        if initialized && !closing { return }
        guard lockFile == -1, !closing else { throw ClientFailure("operation_in_progress") }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Keep the historical lock filename so two app versions cannot write the same database.
        let url = dataDirectory.appendingPathComponent("v2rayN.WebAPI.instance.lock")
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClientFailure("database_open_failed") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ClientFailure("runtime_data_in_use") }
        lockFile = fd
        operation = "startup"
        defer { operation = nil }
        do {
            let restore = NativeBackupRestore(data: dataDirectory)
            let intent = try restore.readIntent()
            if let intent { try restore.undoSwap(intent) } else { try restore.cleanup() }
            let interruptedNode = try await store.interruptedRegionalNode()
            try await store.initializeRuntimeStore(keepRecoveryJournal: interruptedNode != nil)
            if let interruptedNode {
                try await launchSelected(id: interruptedNode)
                try await store.finishEdit()
            }
            try geoAssets.cleanUnused()
            if let intent {
                if let id = intent.runningNode { try await launchSelected(id: id) }
                try restore.finish()
            }
            initialized = true
            if automaticMaintenance {
                maintenance = Task { [weak self] in
                    var minute = 0
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        guard let self else { return }
                        minute += 1
                        await self.runMaintenance(minute: minute)
                    }
                }
            }
            history.append(source: "runtime", lines: ["原生运行服务已就绪"])
        } catch {
            let startupError = error
            // Recovery may have already opened a listener or acquired a TUN lease.
            // Keep the instance lock until cleanup succeeds; stop() can retry it.
            if serving != nil || cleanupPending {
                do { try await disconnect() }
                catch {
                    throw ClientFailure((error as? ClientFailure)?.code ?? "runtime_cleanup_failed",
                                        startupError.localizedDescription + " · " + error.localizedDescription)
                }
            }
            close(fd)
            lockFile = -1
            throw startupError
        }
    }

    public func stop() async throws {
        guard lockFile != -1 else { return }
        closing = true
        defer { closing = false }
        regionTask?.cancel()
        maintenance?.cancel()
        updateTask?.cancel()
        speedTest?.cancel()
        subscriptionUpdate?.cancel()
        _ = await regionTask?.result
        await updateTask?.value
        await maintenance?.value
        maintenance = nil
        subscriptionRetry.removeAll()
        await speedTest?.value
        await subscriptionUpdate?.value
        while operation != nil { try await Task.sleep(for: .milliseconds(20)) }
        try await disconnect()
        initialized = false
        if lockFile >= 0 { close(lockFile); lockFile = -1 }
    }

    private func requireActive() throws {
        guard initialized, !closing else { throw ClientFailure("backend_exited") }
    }

    public func activeOperations() throws -> [String] {
        try requireActive()
        var active: [String] = []
        if let operation { active.append(operation) }
        if subscriptionUpdate != nil { active.append("subscription-update") }
        if speedTest != nil { active.append("speedtest") }
        if updateTask != nil { active.append("geo-update") }
        if regionTask != nil { active.append("regional-preset") }
        return active
    }

    public func runtimeStatus() async throws -> RuntimeStatus {
        try requireActive()
        return try await state()
    }

    public func logTail(after: Int64, limit: Int) async throws -> LogTail {
        try requireActive()
        await collectCoreLogs()
        return history.tail(after: after, limit: limit)
    }

    public func profileMetadata() async throws -> [Profile] {
        try requireActive()
        return try await store.profileCatalog()
    }
    public func profileObservations() async throws -> [ProfileObservation] {
        try requireActive()
        return try await store.profileObservations()
    }
    public func profileDocument(id: String) async throws -> SettingsValue {
        try requireActive()
        return try await store.profileDocument(id: id)
    }
    public func routingProfiles() async throws -> [RoutingProfile] {
        try requireActive()
        return try await store.routingProfiles()
    }

    private func state() async throws -> RuntimeStatus {
        let settings = try await store.readSettings()
        let selected = settings["IndexId"].text
        let profile = selected.isEmpty ? nil : try await store.profileDocument(id: selected)
        if let session = serving, operation == nil {
            let running = await embedded?.running == true
            if serving?.sessionID == session.sessionID, operation == nil, !running {
                operation = "cleanup"
                defer { operation = nil }
                try await disconnect()
                failure = "core_exited"
            }
        }
        let version = embedded?.displayVersion ?? bundledXrayVersion
        var state = RuntimeStatus(coreRunning: serving != nil, xrayAvailable: version != nil,
                                  runtimeState: runtimeState)
        state.currentProfileId = selected.isEmpty ? nil : selected
        state.currentProfileName = profile?["remarks"].text
        state.runningProfileId = serving?.id
        state.runningProfileName = serving?.name
        state.coreStartedAt = serving?.started
        state.coreSessionID = serving?.sessionID
        state.configuredProxyPort = settings["Inbound"].items.first.flatMap { Int($0["LocalPort"].text) }
        state.runningProxyEndpoints = serving?.endpoints
        state.runningProxyPort = serving?.endpoints?.preferredPort
        state.coreProcessIds = serving.map { [$0.pid] } ?? []
        state.runtimeFailure = runtimeFailure
        state.statisticsEnabled = settings["GuiItem"]["EnableStatistics"].flag
        state.trafficEnabled = settings["GuiItem"]["DisplayRealTimeSpeed"].flag || state.statisticsEnabled == true
        state.traffic = state.trafficEnabled == true ? await trafficSampler?.snapshot(at: Date()) : nil
        state.installedXrayVersion = version
        return state
    }

    public func tunStatus(_ mode: TunStatusReadMode) async throws -> MacTunStatus {
        try requireActive()
        let tunSettings = try await store.readSettings()["TunModeItem"]
        try requireActive()
        let enabled = tunSettings["EnableTun"].flag
        let session = currentTunID
        let poll = helperObservation.begin()
        var result: HelperResponse
        if !mayContactHelper {
            result = HelperResponse(success: false, code: "helper_isolated", state: "unavailable")
        } else if mode == .verifyHelper || enabled || serving?.tun == true {
            result = await helper.status(fresh: mode != .normal, requiresIPv6: tunSettings["EnableIPv6Address"].flag)
            try Task.checkCancellation()
        } else {
            // Reading registration is passive. Polling XPC would wake the privileged daemon in proxy mode.
            let registered = SMAppService.daemon(plistName: "io.github.CJMVPU.v2rayM.tun-helper.plist").status == .enabled
            result = HelperResponse(success: registered, code: registered ? "ok" : "helper_unavailable",
                                    state: registered ? "ready" : "unavailable")
        }
        try requireActive()
        if session != currentTunID { return try await tunStatus(mode) }
        if let session {
            if helperObservation.record(result, for: session, poll: poll) {
                history.append(source: "core", lines: result.logs)
            } else if let latest = helperObservation.response(for: session) { result = latest }
        }
        return MacTunStatus(platformSupported: true, helperAvailable: result.success, helperCode: result.code,
                            helperState: result.success ? "ready" : result.state, enabled: enabled,
                            supportedCores: ["xray"], coreSource: "embedded-xray",
                            runtimeState: runtimeState,
                            privilegedCoreProcessIds: [],
                            confirmedInactiveSessionID: result.success && ["idle", "stopped"].contains(result.state) ? session : nil,
                            tunnelForwardingPID: session != nil && result.success && result.state == "running" ? Int(getpid()) : nil)
    }

    private func mutate<T>(_ name: String, waitingForGeoActivation onWait: (() -> Void)? = nil,
                           _ work: () async throws -> T) async throws -> T {
        if let onWait, operation != nil, !closing {
            onWait()
            let (changes, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            geoActivationSignal = signal
            // A settings edit can still be waiting for its own remote source. Do not
            // block it, poll the actor, or leave a manual update pending forever.
            let deadline = Task {
                try await Task.sleep(for: .seconds(120))
                signal.finish()
            }
            defer { deadline.cancel(); signal.finish(); geoActivationSignal = nil }
            for await _ in changes {
                if operation == nil || closing { break }
            }
            try Task.checkCancellation()
            guard operation == nil || closing else {
                throw ClientFailure("geo_activation_timeout", "等待当前操作结束超时，请稍后更新")
            }
        }
        try requireActive()
        guard operation == nil else { throw ClientFailure("operation_in_progress") }
        operation = name
        defer { operation = nil }
        return try await work()
    }

    public func proxyConnection() async throws -> ProxyConnection {
        try requireActive()
        let current = try await state()
        return ProxyConnection(running: current.coreRunning, endpoints: current.runningProxyEndpoints)
    }
    public func startCore() async throws {
        try await mutate("start") { try await launchSelected() }
    }

    public func stopCore() async throws {
        try await mutate("stop") { try await disconnect() }
    }

    public func restartCore() async throws {
        try await mutate("restart") {
            try await disconnect()
            try await launchSelected()
        }
    }

    public func setTunEnabled(_ enabled: Bool) async throws {
        try await mutate("mode") {
            let original = try await store.readSettings()
            guard original["TunModeItem"]["EnableTun"].flag != enabled else { return }
            if enabled {
                guard mayContactHelper else { throw ClientFailure("mac_tun_helper_unavailable") }
                let status = await helper.status(fresh: true, requiresIPv6: original["TunModeItem"]["EnableIPv6Address"].flag)
                guard status.success else { throw ClientFailure(status.code == "helper_protocol_mismatch" ? status.code : "mac_tun_helper_unavailable") }
            }
            var changed = original
            changed["TunModeItem"]["EnableTun"] = .bool(enabled)
            try await changeSettings(from: original, to: changed, connect: serving != nil)
        }
    }

    @discardableResult public func saveProfile(id: String, original: SettingsValue, edited: SettingsValue) async throws -> SettingsValue {
        try await mutate("editProfile") {
            guard let running = serving else {
                return try await store.updateProfile(id: id, original: original, edited: edited)
            }
            let before = try await store.configurationSnapshot()
            let updated = try await store.updateProfile(id: id, original: original, edited: edited, commit: false)
            guard before.original(id) != updated else { return updated }
            let after = before.replacingProfile(id, with: updated)
            var saved = updated
            try await applyProfileChange(before: before, after: after, next: running.id) {
                saved = try await store.updateProfile(id: id, original: original, edited: edited)
            }
            return saved
        }
    }

    /// Start the complete candidate graph before touching persistent profiles or managed files.
    /// A conflict, cancellation, or failed replacement restores the previously serving graph.
    @discardableResult
    private func applyProfileChange(before: XrayConfigurationSnapshot, after: XrayConfigurationSnapshot,
                                    next: String?, commit: () async throws -> Void) async throws -> Bool {
        guard let running = serving else { try await commit(); return false }
        let now = Date()
        let hasIPv6 = running.tun && Self.hasGlobalIPv6()
        func generated(_ snapshot: XrayConfigurationSnapshot, id: String) throws -> [SettingsValue] {
            var result = [try snapshot.generate(nodeID: id, metricsPort: nil, tunnelInterface: running.tun ? "utun0" : nil,
                                                hasGlobalIPv6: hasIPv6, at: now)]
            if let node = snapshot.nodesByID[id], let port = Self.prePort(for: node) {
                result.append(try snapshot.generate(nodeID: id, metricsPort: nil, at: now, preSocksPort: port))
            }
            return result
        }
        if let next {
            let candidate = try generated(after, id: next)
            if next == running.id, try generated(before, id: next) == candidate {
                try await commit()
                serving?.name = after.nodesByID[next]?["remarks"].text ?? running.name
                return false
            }
        }
        return try await ServingProfileReplacement.apply(next: next, disconnect: { try await self.disconnect() },
            launch: { id in try await self.launchSelected(id: id, snapshot: after) }, commit: commit,
            restorePrevious: { try await self.launchSelected(id: running.id, snapshot: before) })
    }

    /// Keep a reversible snapshot until both persistence and the serving core acknowledge the edit.
    private func applyRuntimeEdit<T>(table: ConfigurationTable? = nil, affectsCore: Bool = true,
                                  _ edit: () async throws -> T) async throws -> T {
        try await mutate("settings") {
            let running = serving
            let at = Date()
            func generated() async throws -> SettingsValue? {
                guard let running, affectsCore else { return nil }
                let node = try await store.profileDocument(id: running.id)
                let prePort = Self.prePort(for: node)
                return try await store.generateXrayConfiguration(nodeID: running.id, metricsPort: nil,
                    tunnelInterface: running.tun ? "utun0" : nil, hasGlobalIPv6: running.tun && Self.hasGlobalIPv6(), at: at, preSocksPort: prePort)
            }
            let before = try await generated()
            var disconnected = false
            try await store.beginEdit(table: table)
            do {
                let result = try await edit()
                if let running, let before {
                    do {
                        let after = try await generated()
                        if let after, before != after {
                            try XrayInbound.checkNewListeners(before: before["inbounds"].items, after: after["inbounds"].items)
                            try await disconnect()
                            disconnected = true
                            try await launchSelected(id: running.id)
                        }
                    } catch { throw ClientFailure("settings_core_apply_failed", (error as? ClientFailure)?.code) }
                }
                if let sampler = trafficSampler {
                    let gui = try await store.readSettings()["GuiItem"]
                    await sampler.setStatistics(gui["EnableStatistics"].flag)
                }
                try await store.finishEdit()
                return result
            } catch {
                let cause = error
                try await store.recoverEdit()
                if let running, disconnected {
                    try await Task {
                        try await self.disconnect()
                        try await self.launchSelected(id: running.id)
                    }.value
                }
                throw cause
            }
        }
    }

    private func changeSettings(from original: SettingsValue, to updated: SettingsValue, connect: Bool) async throws {
        let previous = serving
        if original == updated {
            if !connect { return }
            if let previous, previous.id == updated["IndexId"].text,
               previous.tun == updated["TunModeItem"]["EnableTun"].flag,
               !cleanupPending, runtimeFailure == nil, await embedded?.running == true { return }
        }
        if connect && previous != nil { try await disconnect() }
        do {
            try await store.writeSettings(updated)
            if connect { try await launchSelected() }
        } catch {
            let first = error
            try await store.writeSettings(original)
            if connect, let previous { try await launchSelected(id: previous.id) }
            throw first
        }
    }

    private func disconnect() async throws {
        await trafficSampler?.stop(flush: true)
        trafficSampler = nil
        try await cleanSession(ownedBy: nil)
        await collectCoreLogs()
        if serving != nil { history.append(source: "runtime", lines: ["Xray 已停止"]) }
        serving = nil
        failure = nil
    }

    private func cleanSession(ownedBy id: UUID?) async throws {
        // A cancelled startup still owns the rollback. The helper keeps its receipt
        // token and the library keeps its owner until their respective stops succeed.
        let library = embedded, helper = helper
        do {
            try await Task {
                try await RuntimeSessionCleanup.run(stopCore: {
                    if let id { try await library?.stop(ifOwnedBy: id) }
                    else { try await library?.stop() }
                }, restoreNetwork: { try await helper.stop() })
            }.value
            cleanupPending = false
        } catch {
            cleanupPending = true
            failure = (error as? ClientFailure)?.code ?? "runtime_cleanup_failed"
            throw error
        }
    }

    private static func prePort(for node: SettingsValue) -> Int? {
        guard node["configType"].text == "custom", let port = Int(node["preSocksPort"].text), (1...65535).contains(port) else { return nil }
        return port
    }

    private func launchSelected(id: String? = nil, geoDirectory: URL? = nil, snapshot: XrayConfigurationSnapshot? = nil) async throws {
        do {
            try await startSelected(id: id, geoDirectory: geoDirectory, snapshot: snapshot)
        } catch {
            await collectCoreLogs()
            let reason = (error as? ClientFailure)?.detail ?? error.localizedDescription
            history.append(source: "runtime", lines: ["[Error] Xray 启动失败 · " + reason])
            throw error
        }
    }

    private func startSelected(id: String?, geoDirectory: URL?, snapshot: XrayConfigurationSnapshot?) async throws {
        if cleanupPending { try await disconnect() }
        let inputs: XrayConfigurationSnapshot
        if let snapshot { inputs = snapshot } else { inputs = try await store.configurationSnapshot() }
        let settings = inputs.configuration.settings
        let id = id ?? settings["IndexId"].text
        guard !id.isEmpty else { throw ClientFailure("profile_not_selected") }
        let tun = settings["TunModeItem"]["EnableTun"].flag
        if let previous = serving, previous.id == id && previous.tun == tun {
            if try await state().coreRunning && failure == nil { return }
        }
        guard serving == nil else { throw ClientFailure("operation_in_progress") }
        guard let node = inputs.nodesByID[id] else { throw ClientFailure("profile_not_found") }
        if tun {
            guard mayContactHelper else { throw ClientFailure("mac_tun_helper_unavailable") }
            try await checkTunnelConflict()
        }
        let device = tun ? "utun" + String((0..<1024).first { if_nametoindex("utun" + String($0)) == 0 } ?? 1024) : nil
        var generated = try inputs.generate(nodeID: id, metricsPort: nil, tunnelInterface: device,
                                                                  hasGlobalIPv6: tun && Self.hasGlobalIPv6())
        let custom = node["configType"].text == "custom"
        let prePort = Self.prePort(for: node)
        let frontend: SettingsValue
        if let prePort {
            frontend = try inputs.generate(nodeID: id, metricsPort: nil, preSocksPort: prePort)
        } else { frontend = generated }
        let endpoints = XrayInbound.proxyEndpoints(frontend["inbounds"].items)
        do {
            let source = try geoDirectory ?? geoAssets.active()
            let pid: Int32
            let sessionID = UUID()
            let library = try loadEmbedded()
            if tun {
                do {
                    let (name, handle) = try await helper.prepare(config: generated, token: sessionID) {
                        Task { try? await library.stop(ifOwnedBy: sessionID) }
                    }
                    defer { try? handle.close() }
                    var inbounds = generated["inbounds"].items
                    if let index = inbounds.firstIndex(where: { $0["protocol"].text == "tun" }) {
                        inbounds[index]["settings"]["name"] = .string(name)
                    }
                    generated["inbounds"] = .array(inbounds)
                    try await library.start(config: generated, assets: source, tunnel: handle, sessionID: sessionID)
                    try await helper.activate(token: sessionID)
                    try Task.checkCancellation()
                    pid = getpid()
                } catch {
                    let cause = error
                    do { try await cleanSession(ownedBy: sessionID) }
                    catch {
                        throw ClientFailure((error as? ClientFailure)?.code ?? "runtime_cleanup_failed",
                                            cause.localizedDescription + " · " + error.localizedDescription)
                    }
                    throw cause
                }
            } else {
                try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("guiLogs"),
                                                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let displayLogs = !custom || node["displayLog"] == .null || node["displayLog"].flag
                try await library.start(config: frontend, assets: source, sessionID: sessionID,
                                               custom: prePort == nil ? nil : generated, displayLogs: displayLogs)
                pid = getpid()
            }
            serving = (id, node["remarks"].text, endpoints, pid, tun, ISO8601DateFormatter().string(from: Date()), sessionID)
            let gui = settings["GuiItem"]
            if frontend["stats"] != .null && (gui["DisplayRealTimeSpeed"].flag || gui["EnableStatistics"].flag) {
                let sampler = NativeTrafficSampler(store: store, nodeID: id, statistics: gui["EnableStatistics"].flag) {
                    await library.trafficKiB(for: sessionID)
                }
                trafficSampler = sampler
                await sampler.start()
            }
            failure = nil
            history.append(source: "runtime", lines: ["Xray 已启动"])
        } catch {
            failure = (error as? ClientFailure)?.code ?? "core_start_failed"
            throw error
        }
    }

    private static func hasGlobalIPv6() -> Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return false }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET6,
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let inet = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            if withUnsafeBytes(of: inet, { ($0.first ?? 0) & 0xe0 == 0x20 }) { return true }
        }
        return false
    }
    private static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientFailure("invalid_port") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard ok else { throw ClientFailure("invalid_port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func measureNode(_ node: Profile, action: NativeSpeedAction, settings: SettingsValue,
                             original: SettingsValue, diagnostic: NativeDiagnosticAttempt?) async throws {
        let speedSettings = settings["SpeedTestItem"]
        let download = action == .speedtest || action == .mixedtest
        var speed: Double? = download ? 0 : nil
        var ipInfo: String?
        let delay: Int
        if action == .tcping {
            delay = try await NativeLatencyTest.measure(node)
        } else {
            guard let diagnostic, let config = diagnostic.configuration else { throw ClientFailure("speedtest_invalid_profile") }
            let udp = action == .udptest
            let showIP = !udp && !settings["UiItem"]["HideColumnIpInfo"].flag
            let request: SettingsValue = .object([
                "action": .string(udp ? "udp" : "realping"),
                "url": speedSettings[udp ? "UdpTestTarget" : "SpeedPingTestUrl"], "timeout": speedSettings["SpeedTestTimeout"],
                "downloadURL": download ? speedSettings["SpeedTestUrl"] : .null, "ipURL": showIP ? speedSettings["IPAPIUrl"] : .null
            ])
            let result = try await loadEmbedded().measure(id: diagnostic.id, configuration: config, assets: geoAssets.active(), request: request)
            if result["interrupted"].flag { return }
            delay = Int(result["delay"].text) ?? -1
            if download, let rate = Double(result["speed"].text), rate > 0 { speed = (rate * 10).rounded() / 10 }
            if showIP && delay > 0 { ipInfo = NativeLatencyTest.ipDescription(result["ipInfo"]) }
        }
        try Task.checkCancellation()
        guard try await store.recordLatency(delay, for: node, speed: speed, ipInfo: ipInfo, original: original, attempt: diagnostic) else { return }
        history.append(source: "speedtest", lines: ["\(node.remarks) · \(delay) ms" + (speed.map { String(format: " · %.1f MB/s", $0) } ?? "")])
    }

    private func startLatencyTests(ids: [String], action: NativeSpeedAction = .tcping, single: Bool = false) async throws {
        guard speedTest == nil else { throw ClientFailure("speedtest_busy") }
        let wanted = Set(ids)
        let selected = try await store.profileCatalog(group: wanted.isEmpty ? nil : "").filter { wanted.isEmpty || wanted.contains($0.id) }
        if single && selected.first?.canTest != true { throw ClientFailure("speedtest_invalid_profile") }
        let supported = ["vMess", "vless", "trojan", "shadowsocks", "hysteria2", "wireGuard", "masque", "socks", "http", "custom", "outbound", "proxyChain", "policyGroup"]
        if action != .tcping && selected.contains(where: { $0.coreType != "xray" || !supported.contains($0.protocol) }) {
            throw ClientFailure("speedtest_core_unsupported")
        }
        let nodes = selected.filter { $0.canTest || (action != .tcping && ["proxyChain", "policyGroup", "outbound"].contains($0.protocol)) }
        guard !nodes.isEmpty else { throw ClientFailure("speedtest_profile_selection_required") }
        let snapshot = action == .tcping ? nil : try await store.configurationSnapshot()
        let settings: SettingsValue
        if let snapshot { settings = snapshot.configuration.settings } else { settings = try await store.readSettings() }
        let concurrency = action == .speedtest ? 1 : action == .mixedtest ? max(1, Int(settings["SpeedTestItem"]["MixedConcurrencyCount"].text) ?? 10) : 10
        guard initialized, !closing, operation == nil, speedTest == nil else { throw ClientFailure("speedtest_busy") }
        speedTest = Task {
            defer { speedTest = nil }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var pending = nodes.makeIterator()
                    func enqueue(_ node: Profile) {
                        group.addTask {
                            let original: SettingsValue?
                            if let snapshot { original = snapshot.original(node.id) }
                            else { original = try? await self.store.profileDocument(id: node.id) }
                            guard let original else { return }
                            try Task.checkCancellation()
                            let diagnostic = snapshot.map { NativeDiagnosticAttempt(node: node, snapshot: $0) }
                            do {
                                try await self.measureNode(node, action: action, settings: settings, original: original, diagnostic: diagnostic)
                            } catch {
                                try Task.checkCancellation()
                                try await self.store.recordLatency(-1, for: node, speed: action == .speedtest || action == .mixedtest ? 0 : nil, original: original, attempt: diagnostic)
                            }
                        }
                    }
                    for _ in 0..<min(concurrency, nodes.count) { if let next = pending.next() { enqueue(next) } }
                    while try await group.next() != nil {
                        try Task.checkCancellation()
                        if let next = pending.next() { enqueue(next) }
                    }
                }
            } catch {
                if !Task.isCancelled { history.append(source: "speedtest", lines: ["测速失败"]) }
            }
        }
    }

    private func applySubscription(_ plan: SubscriptionReplacement) async throws {
        guard let running = serving else { try await store.commitSubscription(plan); return }
        let before = try await store.configurationSnapshot()
        let after = try before.replacingSubscription(plan)
        try await applyProfileChange(before: before, after: after, next: running.id) {
            try await store.commitSubscription(plan)
        }
    }

    public func updateSubscriptions(id: String, useProxy: Bool) async throws {
        try requireActive()
        guard subscriptionUpdate == nil else { throw ClientFailure("subscription_update_busy") }
        let subscriptions = try await (id.isEmpty ? store.subscriptions() : [store.subscription(id: id)])
        let selected = subscriptions.filter { $0.enabled && !$0.url.isEmpty }
        let converter = try await store.readSettings()["ConstItem"]["SubConvertUrl"].text
        guard initialized, !closing, operation == nil, subscriptionUpdate == nil else { throw ClientFailure("subscription_update_busy") }
        subscriptionUpdate = Task {
            defer { subscriptionUpdate = nil }
            for item in selected {
                do {
                    try Task.checkCancellation()
                    let rows = try await SubscriptionDownload.fetch(item, proxyEndpoints: useProxy ? serving?.endpoints : nil, converter: converter)
                    try await mutate("applySubscription") {
                        try await store.withSubscriptionReplacement(item, rows: rows, serving: serving?.id) { plan in
                            try await self.applySubscription(plan)
                        }
                    }
                    subscriptionRetry.removeValue(forKey: item.id)
                    history.append(source: "subscription", lines: ["订阅已更新，节点数量 \(rows.count)"])
                } catch {
                    if Task.isCancelled { return }
                    subscriptionRetry[item.id] = Date().addingTimeInterval(300)
                    // Subscription addresses and HTTP error descriptions may contain credentials.
                    history.append(source: "subscription", lines: [(error as? ClientFailure)?.code ?? "subscription_update_failed"])
                }
            }
        }
    }

    func runMaintenance(minute: Int) async {
        guard initialized, !closing, let settings = try? await store.readSettings() else { return }
        let interval = Int(settings["GuiItem"]["AutoUpdateInterval"].text) ?? 0
        for action in MaintenanceAction.due(minute: minute, geoHours: interval) {
            guard !Task.isCancelled, !closing else { return }
            guard operation == nil else { continue }
            do {
                switch action {
                case .subscriptions:
                    let now = Date()
                    subscriptionRetry = subscriptionRetry.filter { $0.value > now }
                    for item in try await store.subscriptions() {
                        guard !Task.isCancelled, !closing else { return }
                        guard item.enabled, !item.url.isEmpty, item.autoUpdateInterval > 0, subscriptionRetry[item.id] == nil,
                              now.timeIntervalSince1970 - Double(item.updateTime) >= Double(item.autoUpdateInterval) * 60,
                              subscriptionUpdate == nil else { continue }
                        try await updateSubscriptions(id: item.id, useProxy: true)
                        await subscriptionUpdate?.value
                    }
                case .saveState:
                    try await mutate("checkpoint") { try await store.checkpoint() }
                case .cleanFiles:
                    try NativeMaintenance.clean(in: dataDirectory, now: Date())
                case .geo:
                    try submitGeoUpdate(useProxy: nil)
                    await updateTask?.value

                }
            } catch {
                if Task.isCancelled || closing { return }
                history.append(source: "task", lines: [(error as? ClientFailure)?.code ?? "maintenance_failed"])
            }
        }
    }

    public func applyRegion(_ name: String) async throws {
        try requireActive()
        let region = ["0":"default","1":"russia","2":"iran"][name] ?? name.lowercased()
        let standard = try RegionalSources.standard(region)
        guard regionTask == nil, updateTask == nil, operation == nil, !closing else { throw ClientFailure("operation_in_progress") }
        let sources = presetSources[region] ?? standard
        let task = Task {
            let base = try await store.regionSnapshot()
            let useProxy = try await store.readSettings()["CheckUpdateItem"]["UpdateViaProxy"].flag
            let endpoints = useProxy ? serving?.endpoints : nil
            let stager = try await store.presetStager(proxyEndpoints: endpoints)
            async let dns = stager.dns(region: region, sources: sources, existing: base.dns)
            async let routes = stager.routes(source: region == "default" ? "" : sources.routingTemplate, base: base, explicitImport: false)
            let candidate = try geoAssets.newGeneration()
            var ownsCandidate = true
            defer { if ownsCandidate { try? FileManager.default.removeItem(at: candidate) } }
            try await NativeGeoAssets.download(to: candidate, source: sources.geoPattern, proxyEndpoints: endpoints) { _, _, _ in }
            try await loadEmbedded().validateGeoDirectory(candidate)
            let staged = try await (dns, routes)
            try Task.checkCancellation()
            return try await mutate("regionalPreset") {
                let old = serving
                guard try await store.regionSnapshot() == base else { throw ClientFailure("regional_preset_conflict") }
                let previous = try RegionalRecovery(generation: geoAssets.currentGeneration(), runningNode: old?.id)
                try await store.beginEdit(table: .routes, regional: previous)
                var reconnect = false
                do {
                    try await store.applyRegion(sources: sources, dns: staged.0, routes: staged.1)
                    try Task.checkCancellation()
                    if let old {
                        reconnect = true
                        try await disconnect()
                        try await launchSelected(id: old.id, geoDirectory: candidate)
                    }
                    try Task.checkCancellation()
                    try geoAssets.commit(candidate)
                    ownsCandidate = false
                    try await store.finishEdit()
                    try? geoAssets.cleanUnused()
                } catch {
                    let cause = error
                    try await Task {
                        if reconnect { try await self.disconnect() }
                        try await self.store.recoverEdit(keepJournal: true)
                        if reconnect, let old { try await self.launchSelected(id: old.id) }
                        try await self.store.finishEdit()
                    }.value
                    throw cause
                }
            }
        }
        regionTask = task
        defer { regionTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func geoDownloadProgress(transfer: UUID, files: Int, bytes: Int64, total: Int64?, batch: Bool) {
        guard geoTransferID == transfer, let previous = latestGeoProgress, previous.phase == "downloading" else { return }
        guard files >= (previous.completedFiles ?? 0) else { return }
        if files == previous.completedFiles && bytes < (previous.downloadedBytes ?? 0) { return }
        latestGeoProgress = ModuleUpdateProgress(coreType: "GeoFiles", phase: "downloading", isComplete: false,
            success: false, batch: batch, downloadedBytes: bytes, totalBytes: total, completedFiles: files, totalFiles: 2)
    }

    private func runGeoUpdate(proxyOverride: Bool?, batch: Bool) async throws {
        let settings = try await store.readSettings()
        let source = settings["ConstItem"]["GeoSourceUrl"].text
        let useProxy = proxyOverride ?? settings["CheckUpdateItem"]["UpdateViaProxy"].flag
        let candidate = try geoAssets.newGeneration()
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: candidate) } }
        func publish(_ phase: String, done: Bool = false) {
            latestGeoProgress = ModuleUpdateProgress(coreType: "GeoFiles", phase: phase, isComplete: done, success: done, batch: batch)
        }
        let transfer = UUID()
        geoTransferID = transfer
        defer { geoTransferID = nil }
        publish("downloading")
        try await NativeGeoAssets.download(to: candidate, source: source,
                                           proxyEndpoints: useProxy ? serving?.endpoints : nil) { [weak self] count, bytes, total in
            await self?.geoDownloadProgress(transfer: transfer, files: count, bytes: bytes, total: total, batch: batch)
        }
        publish("verifying")
        try await loadEmbedded().validateGeoDirectory(candidate)
        try await mutate("applyGeoFiles", waitingForGeoActivation: { publish("waiting-to-apply") }) {
            try Task.checkCancellation()
            guard try await store.readSettings()["ConstItem"]["GeoSourceUrl"].text == source else {
                throw ClientFailure("geo_update_source_changed")
            }
            if try geoAssets.matchesActive(candidate) { return }
            let old = serving
            if old != nil { publish("stopping-core"); try await disconnect() }
            do {
                if let old {
                    publish("restarting-core")
                    try await launchSelected(id: old.id, geoDirectory: candidate)
                }
                try Task.checkCancellation()
                try geoAssets.commit(candidate)
                committed = true
            } catch {
                let cause = error
                if let old {
                    publish("rolling-back")
                    try await Task {
                        try await self.disconnect()
                        try await self.launchSelected(id: old.id)
                    }.value
                }
                throw cause
            }
        }
        do { try geoAssets.cleanUnused() } catch { history.append(source: "update", lines: ["旧 Geo 文件将在启动时清理"]) }
        publish("completed", done: true)
    }

    public func geoUpdateProgress() throws -> ModuleUpdateProgress? {
        try requireActive()
        return latestGeoProgress
    }

    public func submitGeoUpdate(useProxy: Bool?) throws {
        try startGeoUpdate(useProxy: useProxy, batch: false)
    }

    private func startGeoUpdate(useProxy: Bool?, batch: Bool) throws {
        try requireActive()
        guard updateTask == nil, regionTask == nil, operation == nil else { throw ClientFailure("core_update_busy") }
        latestGeoProgress = ModuleUpdateProgress(coreType: "GeoFiles", phase: "queued", isComplete: false, success: false, batch: batch)
        updateTask = Task {
            defer { updateTask = nil }
            do {
                try Task.checkCancellation()
                try await runGeoUpdate(proxyOverride: useProxy, batch: batch)
            } catch {
                let failure = error as? ClientFailure
                let safeDetail = ["geo_download_failed", "geo_activation_timeout"].contains(failure?.code ?? "") ? failure?.detail : nil
                let detail = Task.isCancelled ? "已取消" : safeDetail ?? failure?.code ?? "module_update_failed"
                latestGeoProgress = ModuleUpdateProgress(coreType: "GeoFiles", phase: "failed", isComplete: true, success: false,
                                                                  detail: detail, batch: batch)
                history.append(source: "update", lines: ["GeoFiles " + detail])
            }
        }
    }

    private func removeProfiles(_ requested: [String], subscription: String? = nil) async throws -> ProfileRemovalResult {
        try await mutate("deleteProfiles") {
            let ids = try await store.removalIDs(requested, subscription: subscription)
            let wasServing = serving != nil
            let restart = try await applyRemoval(ids, subscription: subscription)
            return ProfileRemovalResult(deleted: ids.count, coreRestarted: restart, stoppedServing: wasServing && serving == nil)
        }
    }

    private func applyRemoval(_ ids: [String], subscription: String? = nil) async throws -> Bool {
        guard !ids.isEmpty || subscription != nil else { return false }
        let before = try await store.configurationSnapshot()
        let after = try before.removingProfiles(Set(ids), subscription: subscription)
        var next = serving?.id
        if let current = next, after.nodesByID[current] == nil {
            let selected = before.configuration.settings["IndexId"].text
            let fallback = after.nodesByID[selected] == nil ? after.configuration.nodes.first?["indexId"].text : selected
            next = subscription == nil ? fallback : nil
        }
        let restart = try await applyProfileChange(before: before, after: after, next: next) {
            try await store.commitProfileRemoval(ids, subscription: subscription)
        }
        try await store.finishProfileRemoval()
        return restart
    }

    private func restoreArchive(_ file: URL, scratch: URL) async throws -> SettingsValue {
        let restore = NativeBackupRestore(data: dataDirectory)
        guard regionTask == nil, updateTask == nil, speedTest == nil, subscriptionUpdate == nil else { throw ClientFailure("operation_in_progress") }
        let intent = NativeBackupRestore.Intent(id: UUID(), runningNode: serving?.id)
        do { try restore.prepare(file) }
        catch {
            if try restore.readIntent() == nil { try? restore.cleanup() }
            throw error
        }
        let backups = dataDirectory.appendingPathComponent("guiBackups")
        let safety = backups.appendingPathComponent("before-restore-" + intent.id.uuidString + ".zip")
        var journalWritten = false, oldStopped = false
        do {
            try NativeBackupArchive.privateDirectory(backups)
            do { try await store.createBackup(in: scratch, at: safety, forLocalRollback: true) }
            catch { try? FileManager.default.removeItem(at: safety); throw ClientFailure("backup_safety_copy_failed") }
            try Task.checkCancellation()
            try restore.begin(intent)
            journalWritten = true
            if serving != nil { try await disconnect(); oldStopped = true }
            try restore.buildCandidate()
            let candidateStore = NativeConfigurationStore(dataDirectory: restore.staging)
            try await candidateStore.initializeRuntimeStore()
            try Task.checkCancellation()
            try restore.activate(intent)
            if oldStopped { try await launchSelected() }
            try restore.finish()
            return .object(["safetyBackup": .string(safety.lastPathComponent), "restartRequired": .bool(false)])
        } catch {
            let cause = error
            if journalWritten {
                try await Task {
                    if oldStopped && self.serving != nil { try await self.disconnect() }
                    try restore.undoSwap(intent)
                    if oldStopped, let id = intent.runningNode { try await self.launchSelected(id: id) }
                    try restore.finish()
                }.value
            } else { try? restore.cleanup() }
            throw cause
        }
    }

    // MARK: - Settings and routing

    public func settings() async throws -> SettingsValue {
        try requireActive()
        return try await NativeSettings.view(store.readSettings(), options: store.builtin("settings-options"))
    }

    public func settingsSection(_ section: NativeSettingsSection) async throws -> SettingsValue {
        try requireActive()
        return try await NativeSettings.section(section.rawValue, from: store.readSettings())
    }

    public func saveSettings(_ section: NativeSettingsSection, _ input: SettingsValue) async throws {
        try await applyRuntimeEdit(affectsCore: section != .speedTest && section != .webDAV) {
            let original = try await store.readSettings()
            let updated = try await NativeSettings.applying(input, section: section.rawValue, to: original, options: store.builtin("settings-options"))
            if updated != original { try await store.writeSettings(updated) }
        }
    }

    public func editorResource(_ resource: NativeEditorResource) async throws -> SettingsValue {
        try requireActive()
        return try await store.builtin(resource.rawValue)
    }

    public func configurationProfiles(_ kind: CoreConfigurationProfile) async throws -> SettingsValue {
        try requireActive()
        return .array(try await store.coreConfigurationProfiles(kind))
    }

    public func saveConfigurationProfile(_ kind: CoreConfigurationProfile, _ input: SettingsValue) async throws {
        try await applyRuntimeEdit(table: kind.table) { try await store.saveCoreConfigurationProfile(kind, input: input) }
    }

    public func routeDocuments() async throws -> SettingsValue {
        try requireActive()
        return .array(try await store.routeDocuments())
    }

    public func routingRules(id: String) async throws -> SettingsValue {
        try requireActive()
        return .array(try await store.routingRules(id: id))
    }

    @discardableResult public func saveRoute(id: String?, _ input: SettingsValue) async throws -> String {
        return try await applyRuntimeEdit(table: .routes) { try await store.saveRoute(input, id: id) }
    }

    public func activateRoute(_ id: String) async throws {
        try await applyRuntimeEdit(table: .routes) { try await store.selectRoute(id, delete: false) }
    }

    public func deleteRoute(_ id: String) async throws {
        try await applyRuntimeEdit(table: .routes) { try await store.selectRoute(id, delete: true) }
    }

    public func editRules(_ id: String, _ edit: RoutingRuleEdit) async throws {
        try await applyRuntimeEdit(table: .routes) { try await store.editRules(id, edit: edit) }
    }

    public func importRoutes() async throws {
        try await applyRuntimeEdit(table: .routes) {
            let base = try await store.regionSnapshot()
            let stager = try await store.presetStager(proxyEndpoints: serving?.endpoints)
            let plan = try await stager.routes(source: base.routeURL.text, base: base, explicitImport: true)
            try Task.checkCancellation()
            try await store.importRoutes(plan)
        }
    }

    public func importRules(_ id: String, content: String?, append: Bool) async throws {
        try await applyRuntimeEdit(table: .routes) {
            let text: String
            if let content {
                text = content
            } else {
                let address = try await store.routingSource(id: id)
                guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil else {
                    throw ClientFailure("routing_url_invalid")
                }
                do { text = try await SubscriptionDownload.download(URLRequest(url: url), proxyEndpoints: serving?.endpoints) }
                catch { try Task.checkCancellation(); throw ClientFailure("routing_url_download_failed") }
            }
            let rules = try NativeConfigurationStore.parseRoutingRules(text)
            try await store.editRules(id, edit: .save(rules, append: append))
        }
    }

    // MARK: - Profiles and subscriptions

    public func profiles(group: String?, search: String?, includeStatistics: Bool = true) async throws -> [Profile] {
        try requireActive()
        return try await store.profileCatalog(group: group, includeStatistics: includeStatistics, search: search)
    }

    public func selectProfile(_ id: String, connect: Bool) async throws {
        try await mutate("select") {
            if !connect, serving != nil { throw ClientFailure("core_selection_requires_stop") }
            let node = try await store.profileDocument(id: id)
            let old = try await store.readSettings()
            var updated = old
            updated["IndexId"] = node["indexId"]
            try await changeSettings(from: old, to: updated, connect: connect)
        }
    }

    @discardableResult public func importProfiles(_ content: String, group: String?, isSubscription: Bool) async throws -> Int {
        return try await mutate("importProfiles") { try await store.importProfiles(content: content, groupID: group, isSubscription: isSubscription) }
    }

    public func exportProfiles(_ options: SettingsValue) async throws -> [SettingsValue] {
        return try await mutate("exportProfiles") { try await store.exportProfiles(options, metricsPort: Self.freeLoopbackPort()) }
    }

    @discardableResult public func deleteProfiles(_ ids: [String]) async throws -> ProfileRemovalResult {
        return try await removeProfiles(ids)
    }

    public func copyProfiles(_ ids: [String]) async throws {
        try await mutate("copyProfiles") { try await store.copyProfiles(ids) }
    }

    public func moveProfiles(_ ids: [String], to group: String) async throws {
        try await mutate("moveProfiles") {
            guard let running = serving else { return try await store.moveProfiles(ids, group: group) }
            let before = try await store.configurationSnapshot()
            let after = before.movingProfiles(Set(ids), to: group)
            try await applyProfileChange(before: before, after: after, next: running.id) {
                try await store.moveProfiles(ids, group: group)
            }
        }
    }

    public func selectGroup(_ id: String) async throws {
        try await mutate("selectGroup") { try await store.selectGroup(id) }
    }

    public func moveProfile(_ id: String, direction: String, position: Int) async throws {
        try await mutate("moveProfile") { try await store.moveProfile(id: id, direction: direction, position: position) }
    }

    public func sortProfiles(group: String?, column: String, ascending: Bool) async throws {
        try await mutate("sortProfiles") { try await store.sortProfiles(group: group, column: column, ascending: ascending) }
    }

    @discardableResult public func cleanProfiles(group: String?, duplicates: Bool) async throws -> Int {
        return try await mutate("cleanProfiles") {
            let ids = try await store.maintenanceRemovalIDs(group: group, duplicates: duplicates, serving: serving?.id)
            _ = try await applyRemoval(ids)
            return ids.count
        }
    }

    @discardableResult public func generateGroups(subscription: String, regions: Bool) async throws -> SettingsValue {
        return try await mutate("generateGroups") { try await store.generateGroups(subscription: subscription, regions: regions) }
    }

    public func subscriptions() async throws -> [Subscription] {
        try requireActive()
        return try await store.subscriptions()
    }

    public func subscription(id: String) async throws -> Subscription {
        try requireActive()
        return try await store.subscription(id: id)
    }

    public func subscriptionShare(id: String) async throws -> (id: String, url: String) {
        let group = try await subscription(id: id)
        return (group.id, group.url)
    }

    @discardableResult public func saveSubscription(id: String?, _ input: SettingsValue) async throws -> Subscription {
        return try await mutate("saveSubscription") { try await store.saveSubscription(input, id: id) }
    }

    @discardableResult public func deleteSubscription(_ id: String) async throws -> ProfileRemovalResult {
        return try await removeProfiles([], subscription: id)
    }

    // MARK: - Diagnostics and updates

    public func testLatency(_ id: String) async throws {
        try requireActive()
        try await startLatencyTests(ids: [id], single: true)
    }

    public func testProfiles(_ ids: [String], action: NativeSpeedAction) async throws {
        try requireActive()
        try await startLatencyTests(ids: ids, action: action)
    }

    public func cancelSpeedTests() async throws {
        try requireActive()
        speedTest?.cancel()
        await speedTest?.value
    }

    public func clearStatistics() async throws {
        try await mutate("clearStatistics") {
            if let sampler = trafficSampler { await sampler.setStatistics(false) }
            do { try await store.clearStatistics() }
            catch {
                if let sampler = trafficSampler { await sampler.setStatistics(try await store.readSettings()["GuiItem"]["EnableStatistics"].flag) }
                throw error
            }
            if let sampler = trafficSampler { await sampler.setStatistics(try await store.readSettings()["GuiItem"]["EnableStatistics"].flag) }
        }
    }

    public func recentLogs(limit: Int, filter: String?) async throws -> [LogEntry] {
        try requireActive()
        await collectCoreLogs()
        return history.recent(limit: limit, filter: filter)
    }

    public func logPage(_ page: Int, size: Int, filter: String?) async throws -> LogPage {
        try requireActive()
        await collectCoreLogs()
        return history.page(page, size: size, filter: filter)
    }

    public func clearLogs() async throws {
        try requireActive()
        await collectCoreLogs()
        history.clear()
    }

    public func geoPreferences() async throws -> SettingsValue {
        try requireActive()
        return try await NativeGeoUpdatePreferences.settings(store.readSettings())
    }

    public func saveGeoPreferences(_ input: SettingsValue) async throws {
        try await mutate("updatePreferences") {
            let prefs = try NativeGeoUpdatePreferences.applying(input, to: await store.readSettings())
            try await store.writeSettings(prefs)
        }
    }

    public func submitBatchGeoUpdate(apply: Bool, useProxy: Bool?) async throws {
        try requireActive()
        let prefs = NativeGeoUpdatePreferences.settings(try await store.readSettings())
        guard prefs["geoFilesSelected"].flag, apply else { throw ClientFailure("core_update_selection_required") }
        try startGeoUpdate(useProxy: useProxy, batch: true)
    }

    // MARK: - Backup and restore

    private func withBackupArchive<T>(_ work: (URL, URL) async throws -> T) async throws -> T {
        try await mutate("backup") {
            let scratch = dataDirectory.appendingPathComponent("guiTemps/backup-" + UUID().uuidString)
            try NativeBackupArchive.privateDirectory(scratch)
            defer { try? FileManager.default.removeItem(at: scratch) }
            return try await work(scratch, scratch.appendingPathComponent("backup.zip"))
        }
    }

    public func exportBackup() async throws -> Data {
        try requireActive()
        return try await withBackupArchive { scratch, file in
            try await store.createBackup(in: scratch, at: file)
            return try Data(contentsOf: file)
        }
    }

    @discardableResult public func restoreBackup(_ data: Data) async throws -> SettingsValue {
        try requireActive()
        return try await withBackupArchive { scratch, file in
            guard (1...NativeBackupArchive.limit).contains(data.count) else { throw ClientFailure("backup_archive_invalid") }
            try data.write(to: file)
            return try await restoreArchive(file, scratch: scratch)
        }
    }

    public func checkWebDAV() async throws {
        try await mutate("backup") { try await NativeWebDAV(settings: store.readSettings()).probe() }
    }

    public func uploadBackup() async throws {
        try requireActive()
        try await withBackupArchive { scratch, file in
            let dav = try await NativeWebDAV(settings: store.readSettings())
            try await store.createBackup(in: scratch, at: file)
            try await dav.upload(file)
        }
    }

    @discardableResult public func restoreWebDAVBackup() async throws -> SettingsValue {
        try requireActive()
        return try await withBackupArchive { scratch, file in
            try await NativeWebDAV(settings: store.readSettings()).download(to: file)
            return try await restoreArchive(file, scratch: scratch)
        }
    }
}
