import Foundation
import Darwin
import ServiceManagement
import TunShared

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
    private var regionTask: Task<SettingsValue, Error>?
    private let automaticMaintenance: Bool
    private var maintenance: Task<Void, Never>?
    private var subscriptionRetry = [String: Date]()
    private let mayContactHelper: Bool
    private var lockFile: Int32 = -1
    private var initialized = false
    private var closing = false
    private var geoTransferID: UUID?
    private var updateName: String?
    private var updateTask: Task<Void, Never>?
    private var moduleProgress = [String: ModuleUpdateProgress]()
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
        self.bundle = bundle
        bundledXrayVersion = EmbeddedXray.bundledVersion(in: bundle)
        self.presetSources = presetSources
        self.automaticMaintenance = automaticMaintenance
        self.dataDirectory = dataDirectory
        self.mayContactHelper = mayContactHelper
        assets = bundle.appendingPathComponent("Contents/Resources/Backend/bin", isDirectory: true)
        store = NativeConfigurationStore(dataDirectory: dataDirectory)
        helper = NativeHelperSession()
    }

    public func startClient() async throws -> any NativeAPI {
        if initialized && !closing { return self }
        guard lockFile == -1, !closing else { throw ClientFailure("operation_in_progress") }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
            return self
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

    public func runtimeStatus() async throws -> RuntimeStatus {
        guard initialized, !closing else { throw ClientFailure("backend_exited") }
        return try await state()
    }

    public func logTail(after: Int64, limit: Int) async throws -> LogTail {
        guard initialized, !closing else { throw ClientFailure("backend_exited") }
        await collectCoreLogs()
        return history.tail(after: after, limit: limit)
    }

    public func profileMetadata() async throws -> [Profile] { try await store.profileCatalog() }
    public func profileObservations() async throws -> [ProfileObservation] { try await store.profileObservations() }
    public func profileDocument(id: String) async throws -> SettingsValue { try await store.profileDocument(id: id) }
    public func routingProfiles() async throws -> [RoutingProfile] { try await store.routingProfiles() }

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

    public func tunStatus() async throws -> MacTunStatus { try await tunStatus(fresh: false) }
    private func tunStatus(fresh: Bool, verifyHelper: Bool = false) async throws -> MacTunStatus {
        let tunSettings = try await store.readSettings()["TunModeItem"]
        let enabled = tunSettings["EnableTun"].flag
        let session = currentTunID
        let poll = helperObservation.begin()
        var result: HelperResponse
        if !mayContactHelper {
            result = HelperResponse(success: false, code: "helper_isolated", state: "unavailable")
        } else if verifyHelper || enabled || serving?.tun == true {
            result = await helper.status(fresh: fresh, requiresIPv6: tunSettings["EnableIPv6Address"].flag)
            try Task.checkCancellation()
        } else {
            // Reading registration is passive. Polling XPC would wake the privileged daemon in proxy mode.
            let registered = SMAppService.daemon(plistName: "io.github.CJMVPU.v2rayM.tun-helper.plist").status == .enabled
            result = HelperResponse(success: registered, code: registered ? "ok" : "helper_unavailable",
                                    state: registered ? "ready" : "unavailable")
        }
        if session != currentTunID { return try await tunStatus(fresh: fresh, verifyHelper: verifyHelper) }
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
        guard initialized, !closing, operation == nil else { throw ClientFailure("operation_in_progress") }
        operation = name
        defer { operation = nil }
        return try await work()
    }

    public func proxyConnection() async throws -> ProxyConnection {
        let current = try await state()
        return ProxyConnection(running: current.coreRunning, endpoints: current.runningProxyEndpoints)
    }
    public func stopProxyCore() async throws { try await mutate("stop") { try await disconnect() } }
    public func startTunCore() async throws { try await mutate("start") { try await launchSelected() } }
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
        try await disconnect()
        do {
            try Task.checkCancellation()
            if let next { try await launchSelected(id: next, snapshot: after) }
            try Task.checkCancellation()
            try await commit()
        } catch {
            let cause = error
            try await Task {
                try await self.disconnect()
                try await self.launchSelected(id: running.id, snapshot: before)
            }.value
            throw cause
        }
        return next != nil
    }

    /// Keep a reversible snapshot until both persistence and the serving core acknowledge the edit.
    private func applyRuntimeEdit(table: ConfigurationTable? = nil, affectsCore: Bool = true,
                                  _ edit: () async throws -> SettingsValue) async throws -> SettingsValue {
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
            try await TunnelConflict.check()
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

    private func updateSubscriptions(id: String, useProxy: Bool) async throws {
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
        for action in NativeMaintenance.due(minute: minute, geoHours: interval) {
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
                    try startGeoUpdate(query: [:], batch: false)
                    await updateTask?.value

                }
            } catch {
                if Task.isCancelled || closing { return }
                history.append(source: "task", lines: [(error as? ClientFailure)?.code ?? "maintenance_failed"])
            }
        }
    }

    private func applyRegion(_ name: String) async throws -> SettingsValue {
        let region = ["0":"default","1":"russia","2":"iran"][name] ?? name
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
                    return SettingsValue.object(["preset": .string(region)])
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
        guard geoTransferID == transfer, let previous = moduleProgress["GeoFiles"], previous.phase == "downloading" else { return }
        guard files >= (previous.completedFiles ?? 0) else { return }
        if files == previous.completedFiles && bytes < (previous.downloadedBytes ?? 0) { return }
        moduleProgress["GeoFiles"] = ModuleUpdateProgress(coreType: "GeoFiles", phase: "downloading", isComplete: false,
            success: false, batch: batch, downloadedBytes: bytes, totalBytes: total, completedFiles: files, totalFiles: 2)
    }

    private func runGeoUpdate(query: [String: String], batch: Bool) async throws {
        let settings = try await store.readSettings()
        let source = settings["ConstItem"]["GeoSourceUrl"].text
        let useProxy = query["useProxy"].map { $0 == "true" } ?? settings["CheckUpdateItem"]["UpdateViaProxy"].flag
        let candidate = try geoAssets.newGeneration()
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: candidate) } }
        func publish(_ phase: String, done: Bool = false) {
            moduleProgress["GeoFiles"] = ModuleUpdateProgress(coreType: "GeoFiles", phase: phase, isComplete: done, success: done, batch: batch)
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

    private func startGeoUpdate(query: [String: String], batch: Bool) throws {
        guard updateTask == nil, regionTask == nil, !closing, operation == nil else { throw ClientFailure("core_update_busy") }
        if let scope = query["scope"], !["rules", "geo", "all"].contains(scope) { throw ClientFailure("geo_update_scope_invalid") }
        updateName = "geo-update"
        moduleProgress["GeoFiles"] = ModuleUpdateProgress(coreType: "GeoFiles", phase: "queued", isComplete: false, success: false, batch: batch)
        updateTask = Task {
            defer { updateTask = nil; updateName = nil }
            do {
                try Task.checkCancellation()
                try await runGeoUpdate(query: query, batch: batch)
            } catch {
                let failure = error as? ClientFailure
                let safeDetail = ["geo_download_failed", "geo_activation_timeout"].contains(failure?.code ?? "") ? failure?.detail : nil
                let detail = Task.isCancelled ? "已取消" : safeDetail ?? failure?.code ?? "module_update_failed"
                moduleProgress["GeoFiles"] = ModuleUpdateProgress(coreType: "GeoFiles", phase: "failed", isComplete: true, success: false,
                                                                  detail: detail, batch: batch)
                history.append(source: "update", lines: ["GeoFiles " + detail])
            }
        }
    }

    private func removeProfiles(_ requested: [String], subscription: String? = nil) async throws -> SettingsValue {
        try await mutate("deleteProfiles") {
            let ids = try await store.removalIDs(requested, subscription: subscription)
            let restart = try await applyRemoval(ids, subscription: subscription)
            return .object(["deleted": .number(Double(ids.count)), "coreRestarted": .bool(restart)])
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

    private func handleRoute(tail: [String], method: String, input: SettingsValue) async throws -> SettingsValue {
        guard let id = tail.first else {
            if method == "GET" { return .array(try await store.routeDocuments()) }
            if method == "POST" { return try await applyRuntimeEdit(table: .routes) { try await store.saveRoute(input) } }
            throw ClientFailure("native_operation_unavailable")
        }
        if tail == ["import"], method == "POST" {
            return try await applyRuntimeEdit(table: .routes) {
                let base = try await store.regionSnapshot()
                let stager = try await store.presetStager(proxyEndpoints: serving?.endpoints)
                let plan = try await stager.routes(source: base.routeURL.text, base: base, explicitImport: true)
                try Task.checkCancellation()
                try await store.importRoutes(plan)
                return .object([:])
            }
        }
        let path = Array(tail.dropFirst())
        if path == ["rules"], method == "GET" { return .array(try await store.routingRules(id: id)) }
        return try await applyRuntimeEdit(table: .routes) {
            switch (method, path) {
            case ("PUT", []): return try await store.saveRoute(input, id: id)
            case ("DELETE", []): return try await store.selectRoute(id, delete: true)
            case ("POST", ["activate"]): return try await store.selectRoute(id, delete: false)
            case ("PUT", ["rules"]): return try await store.editRules(id, edit: .save(input, append: false))
            case ("POST", ["rules", "move"]):
                return try await store.editRules(id, edit: .move(id: input["ruleId"].text, direction: input["direction"].text,
                                                                  position: Int(input["position"].text) ?? -1))
            case ("POST", ["rules", "import"]), ("POST", ["rules", "import-url"]):
                var text = input["content"].text
                if path.last == "import-url" {
                    let address = try await store.routingSource(id: id)
                    guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil else {
                        throw ClientFailure("routing_url_invalid")
                    }
                    do { text = try await SubscriptionDownload.download(URLRequest(url: url), proxyEndpoints: serving?.endpoints) }
                    catch { try Task.checkCancellation(); throw ClientFailure("routing_url_download_failed") }
                }
                let rules = try NativeConfigurationStore.parseRoutingRules(text)
                return try await store.editRules(id, edit: .save(rules, append: input["append"].flag))
            default:
                if method == "DELETE", path.count == 2, path[0] == "rules" {
                    return try await store.editRules(id, edit: .delete(id: path[1]))
                }
                throw ClientFailure("native_operation_unavailable")
            }
        }
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

    private func backupResponse(_ path: String, method: String, body: Data?) async throws -> Data {
        try await mutate("backup") {
            let scratch = dataDirectory.appendingPathComponent("guiTemps/backup-" + UUID().uuidString)
            try NativeBackupArchive.privateDirectory(scratch)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let file = scratch.appendingPathComponent("backup.zip")
            var result = SettingsValue.object([:])
            switch (path, method) {
            case ("/api/backup/download", "GET"):
                try await store.createBackup(in: scratch, at: file)
                return try Data(contentsOf: file)
            case ("/api/backup/restore", "POST"):
                guard let body, (1...NativeBackupArchive.limit).contains(body.count) else { throw ClientFailure("backup_archive_invalid") }
                try body.write(to: file)
                result = try await restoreArchive(file, scratch: scratch)
            case ("/api/backup/webdav/check", "POST"):
                try await NativeWebDAV(settings: store.readSettings()).probe()
            case ("/api/backup/webdav", "POST"):
                let dav = try await NativeWebDAV(settings: store.readSettings())
                try await store.createBackup(in: scratch, at: file)
                try await dav.upload(file)
            case ("/api/backup/webdav/restore", "POST"):
                try await NativeWebDAV(settings: store.readSettings()).download(to: file)
                result = try await restoreArchive(file, scratch: scratch)
            default: throw ClientFailure("native_operation_unavailable")
            }
            return try JSONEncoder().encode(NativeResponse(data: result))
        }
    }

    public func encodedResponse(_ path: String, method: String, body: Data?) async throws -> Data {
        guard initialized, !closing else { throw ClientFailure("backend_exited") }
        guard let components = URLComponents(string: path) else { throw ClientFailure("invalid_api_path") }
        let parts = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        if components.path.hasPrefix("/api/backup/") {
            return try await backupResponse(components.path, method: method, body: body)
        }
        let input = try body.map { try JSONDecoder().decode(SettingsValue.self, from: $0) } ?? .null
        func reply<T: Encodable>(_ value: T) throws -> Data {
            try JSONEncoder().encode(NativeResponse(data: value))
        }
        let sections = ["/api/settings/inbound":"inbound","/api/settings/core":"core","/api/settings/application":"application",
                        "/api/settings/speedtest":"speedTest","/api/settings/routing":"routing","/api/settings/core-types":"coreTypes",
                        "/api/settings/apply":"apply","/api/settings/dns/simple":"simpleDNS","/api/settings/webdav":"webDAV",
                        "/api/macos/tun/settings":"nativeTun"]
        if let section = sections[components.path] {
            if method == "GET" { return try reply(NativeSettings.section(section,from:await store.readSettings())) }
            if method == "PUT" {
                return try reply(await applyRuntimeEdit(affectsCore: !["speedTest","webDAV"].contains(section)) {
                    let original = try await store.readSettings()
                    let updated = try await NativeSettings.applying(input,section:section,to:original,options:store.builtin("settings-options"))
                    if updated != original { try await store.writeSettings(updated) }
                    return .object([:])
                })
            }
        }
        if parts.count == 4, parts.prefix(3) == ["api","settings","regional-presets"], method == "POST" {
            return try reply(await applyRegion(parts[3].lowercased()))
        }
        let routePrefix = ["api", "settings", "routing-profiles"]
        if parts.starts(with: routePrefix) {
            let tail = Array(parts.dropFirst(routePrefix.count))
            return try reply(await handleRoute(tail: tail, method: method, input: input))
        }
        for (prefix, kind) in [(["api","settings","dns","profiles"], CoreConfigurationProfile.dns),
                               (["api","settings","core-templates"], CoreConfigurationProfile.template)] where parts.starts(with: prefix) {
            let tail = parts.dropFirst(prefix.count)
            if tail.isEmpty, method == "GET" { return try reply(await store.coreConfigurationProfiles(kind)) }
            if tail.count == 1, method == "PUT" {
                guard tail.first?.lowercased() == "xray" else { throw ClientFailure(kind.invalid) }
                return try reply(await applyRuntimeEdit(table: kind.table) {
                    try await store.saveCoreConfigurationProfile(kind, input: input)
                })
            }
        }
        switch (components.path, method) {
        case ("/api/core-updates", "GET"):
            return try reply(NativeGeoUpdatePreferences.settings(await store.readSettings()))
        case ("/api/core-updates/settings", "PUT"):
            try await mutate("updatePreferences") {
                let prefs = try NativeGeoUpdatePreferences.applying(input, to: await store.readSettings())
                try await store.writeSettings(prefs)
            }
        case ("/api/core-updates/progress", "GET"):
            return try reply(moduleProgress.values.sorted { $0.coreType < $1.coreType })
        case ("/api/core-updates/Xray/check", "GET"), ("/api/core/xray/check-update", "GET"),
             ("/api/core-updates/Xray/update", "POST"), ("/api/core/xray/update", "POST"):
            throw ClientFailure("xray_bundled_with_app")
        case ("/api/core/geo/update", "POST"):
            try startGeoUpdate(query: query, batch: false)
        case ("/api/core-updates/batch", "POST"):
            let prefs = NativeGeoUpdatePreferences.settings(try await store.readSettings())
            guard prefs["geoFilesSelected"].flag, input["apply"].flag else { throw ClientFailure("core_update_selection_required") }
            try startGeoUpdate(query: query, batch: true)
        case ("/api/settings", "GET"): return try reply(await NativeSettings.view(store.readSettings(), options:store.builtin("settings-options")))
        case ("/api/settings/dns/editor-options", "GET"): return try reply(await store.builtin("dns-options"))
        case ("/api/settings/dns/defaults", "GET"): return try reply(await store.builtin("dns-defaults"))
        case ("/api/editor-options", "GET"): return try reply(await store.builtin("editor-options"))
        case ("/api/status", "GET"): return try reply(await runtimeStatus())
        case ("/api/operations", "GET"):
            var operations: [String] = []
            if let operation { operations.append(operation) }
            if subscriptionUpdate != nil { operations.append("subscription-update") }
            if speedTest != nil { operations.append("speedtest") }
            if let updateName { operations.append(updateName) }
            if regionTask != nil { operations.append("regional-preset") }
            return try reply(operations)
        case ("/api/macos/tun", "GET"): return try reply(await tunStatus(fresh: query["fresh"] == "true", verifyHelper: query["verifyHelper"] == "true"))
        case ("/api/macos/tun", "PUT"): try await setTunEnabled(input["enabled"].flag)
        case ("/api/core/start", "POST"): try await startTunCore()
        case ("/api/core/stop", "POST"): try await stopProxyCore()
        case ("/api/core/restart", "POST"):
            try await mutate("restart") { try await disconnect(); try await launchSelected() }
        case ("/api/speedtests", "POST"):
            guard let action = NativeSpeedAction(rawValue: input["action"].text.lowercased()) else { throw ClientFailure("speedtest_action_invalid") }
            try await startLatencyTests(ids: input["profileIds"].items.map(\.text), action: action)
        case ("/api/speedtests", "DELETE"), ("/api/latency/stop", "POST"):
            speedTest?.cancel()
            await speedTest?.value
        case ("/api/subscriptions/update", "POST"):
            try await updateSubscriptions(id: input["subscriptionId"].text, useProxy: input["useProxy"].flag)
        case ("/api/subscriptions", "GET"): return try reply(await store.subscriptions())
        case ("/api/subscriptions", "POST"):
            return try reply(await mutate("saveSubscription") { try await store.saveSubscription(input, id: nil) })
        case ("/api/profiles", "DELETE"):
            return try reply(await removeProfiles(input["profileIds"].items.map(\.text)))
        case ("/api/statistics", "DELETE"):
            try await mutate("clearStatistics") {
                if let sampler = trafficSampler { await sampler.setStatistics(false) }
                do { try await store.clearStatistics() }
                catch {
                    if let sampler = trafficSampler { await sampler.setStatistics(try await store.readSettings()["GuiItem"]["EnableStatistics"].flag) }
                    throw error
                }
                if let sampler = trafficSampler { await sampler.setStatistics(try await store.readSettings()["GuiItem"]["EnableStatistics"].flag) }
            }
        case ("/api/profiles/deduplicate", "POST"), ("/api/profiles/invalid-test-results", "DELETE"):
            return try reply(await mutate("cleanProfiles") {
                let ids = try await store.maintenanceRemovalIDs(group: query["subscriptionId"], duplicates: method == "POST", serving: serving?.id)
                _ = try await applyRemoval(ids)
                return SettingsValue.object(["removed": .number(Double(ids.count))])
            })
        case ("/api/profile-groups/generate/all", "POST"), ("/api/profile-groups/generate/regions", "POST"):
            return try reply(await mutate("generateGroups") {
                try await store.generateGroups(subscription: query["subscriptionId"] ?? "", regions: parts.last == "regions")
            })
        case ("/api/profiles/copy", "POST"):
            try await mutate("copyProfiles") { try await store.copyProfiles(input["profileIds"].items.map(\.text)) }
        case ("/api/profiles/move-to-group", "POST"):
            try await mutate("moveProfiles") {
                let ids = input["profileIds"].items.map(\.text), group = input["subscriptionId"].text
                guard let running = serving else { return try await store.moveProfiles(ids, group: group) }
                let before = try await store.configurationSnapshot()
                let after = before.movingProfiles(Set(ids), to: group)
                try await applyProfileChange(before: before, after: after, next: running.id) {
                    try await store.moveProfiles(ids, group: group)
                }
            }
        case ("/api/profile-groups/current", "PUT"):
            try await mutate("selectGroup") { try await store.selectGroup(input["subscriptionId"].text) }
        case ("/api/profiles/move", "POST"):
            try await mutate("moveProfile") {
                try await store.moveProfile(id: input["profileId"].text, direction: input["direction"].text, position: Int(input["position"].text) ?? -1)
            }
        case ("/api/profiles/sort", "POST"):
            try await mutate("sortProfiles") {
                try await store.sortProfiles(group: input["subscriptionId"] == .null ? nil : input["subscriptionId"].text,
                                             column: input["column"].text, ascending: input["ascending"].flag)
            }
        case ("/api/profiles/export", "POST"):
            return try reply(await mutate("exportProfiles") { try await store.exportProfiles(input, metricsPort: Self.freeLoopbackPort()) })
        case ("/api/profiles/import", "POST"):
            let count = try await mutate("importProfiles") {
                try await store.importProfiles(content: input["content"].text, groupID: input["subscriptionId"] == .null ? nil : input["subscriptionId"].text,
                                               isSubscription: input["isSubscription"].flag)
            }
            return try reply(["imported": count])
        case ("/api/profiles", "GET"):
            return try reply(await store.profileCatalog(group: query["subscriptionId"], includeStatistics: query["includeStatistics"] != "false", search: query["filter"]))
        case ("/api/profiles/observations", "GET"): return try reply(await store.profileObservations())
        case ("/api/logs", "GET"):
            await collectCoreLogs()
            return try reply(history.recent(limit: Int(query["limit"] ?? "") ?? 200, filter: query["filter"]))
        case ("/api/logs/page", "GET"):
            await collectCoreLogs()
            return try reply(history.page(Int(query["page"] ?? "") ?? 1, size: Int(query["pageSize"] ?? "") ?? 100, filter: query["filter"]))
        case ("/api/logs/tail", "GET"):
            return try reply(await logTail(after: Int64(query["after"] ?? "") ?? 0, limit: Int(query["limit"] ?? "") ?? 10000))
        case ("/api/logs", "DELETE"):
            await collectCoreLogs()
            history.clear()
        default:
            if parts.count == 4, parts.prefix(2) == ["api","profiles"], parts[3] == "latency", method == "POST" {
                try await startLatencyTests(ids: [parts[2]], single: true)
                return try reply(SettingsValue.object([:]))
            }
            if parts.count == 4, parts.prefix(2) == ["api","subscriptions"], parts[3] == "update", method == "POST" {
                try await updateSubscriptions(id: parts[2], useProxy: query["useProxy"] == "true")
                return try reply(SettingsValue.object([:]))
            }
            if parts.count == 3, parts.prefix(2) == ["api","subscriptions"], method == "DELETE" {
                return try reply(await removeProfiles([], subscription: parts[2]))
            }
            if parts.count == 3, parts.prefix(2) == ["api","subscriptions"], method == "PUT" {
                return try reply(await mutate("saveSubscription") { try await store.saveSubscription(input, id: parts[2]) })
            }
            if parts.count == 4, parts.prefix(2) == ["api","subscriptions"], parts[3] == "share", method == "GET" {
                let subscription = try await store.subscription(id: parts[2])
                return try reply(["id": subscription.id, "url": subscription.url])
            }
            if parts.count == 3, parts.prefix(2) == ["api","profiles"], method == "GET" {
                return try reply(await store.profileDocument(id: parts[2]))
            }
            if parts.count == 4, parts.prefix(2) == ["api","profiles"], parts.last == "select", method == "POST" {
                try await mutate("select") {
                    if query["connect"] == "false", serving != nil { throw ClientFailure("core_selection_requires_stop") }
                    let node = try await store.profileDocument(id: parts[2])
                    let old = try await store.readSettings()
                    var updated = old
                    updated["IndexId"] = node["indexId"]
                    try await changeSettings(from: old, to: updated, connect: query["connect"] != "false")
                }
            } else { throw ClientFailure("native_operation_unavailable", method + " " + components.path) }
        }
        return try reply(SettingsValue.object([:]))
    }
}
private struct NativeResponse<T: Encodable>: Encodable {
    let success = true
    let data: T
}
