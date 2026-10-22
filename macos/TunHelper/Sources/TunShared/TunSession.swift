import Foundation
import Darwin

public protocol ManagedCore: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    var exitCode: Int32 { get }
    func terminate()
    func forceKill()
}

public final class NativeCore: ManagedCore {
    private let lock = NSLock()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let stdin = FileHandle(forReadingAtPath: "/dev/null")!
    private var child: pid_t = 0
    private var running = true
    private var status: Int32 = 0
    public var pid: Int32 { child }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; reap(); return running }
    public var exitCode: Int32 {
        lock.lock(); defer { lock.unlock() }; reap()
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    public init(_ launch: PreparedLaunch, log: @escaping (String) -> Void) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func checked(_ result: Int32, _ step: String) throws {
            if result != 0 { throw HelperFailure("spawn_" + step + "_failed_" + String(result)) }
        }
        try checked(posix_spawn_file_actions_init(&actions), "actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes), "attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        // Explicitly keep the Core in the launchd job's process group. launchd can
        // clean remaining members if the helper itself crashes or is unloaded.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        try checked(posix_spawnattr_setflags(&attributes, flags), "flags")
        try checked(posix_spawnattr_setpgroup(&attributes, getpgrp()), "group")
        var defaults = sigset_t()
        var mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for value in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, value) }
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults), "signals")
        try checked(posix_spawnattr_setsigmask(&attributes, &mask), "mask")
        try checked(posix_spawn_file_actions_addchdir_np(&actions, launch.directory.path), "directory")
        try checked(posix_spawn_file_actions_adddup2(&actions, stdin.fileDescriptor, STDIN_FILENO), "stdin")
        try checked(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO), "stdout")
        try checked(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO), "stderr")
        let arguments = ([launch.executable.path] + launch.arguments).map { strdup($0) } + [nil]
        let environment = launch.environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        let result = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&child, launch.executable.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard result == 0 else { running = false; throw HelperFailure("core_spawn_failed_\(result)") }
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        for pipe in [stdout, stderr] {
            let lines = CoreLogLines()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                for line in lines.append(data, end: data.isEmpty) { log(line) }
                if data.isEmpty { handle.readabilityHandler = nil }
            }
        }
    }
    private func reap() {
        if running && child > 0 {
            let result = waitpid(child, &status, WNOHANG)
            if result == child { running = false }
        }
    }
    private func signal(_ value: Int32) {
        lock.lock(); defer { lock.unlock() }; reap()
        // Only this object reaps the owned child; a live/zombie child PID cannot be reused.
        if running && child > 0 { _ = Darwin.kill(child, value) }
    }
    public func terminate() { signal(SIGTERM) }
    public func forceKill() { signal(SIGKILL) }
    deinit {
        signal(SIGTERM)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }
}

public final class SlotLimiter {
    private let lock = NSLock()
    private var active = Set<UUID>()
    public init() {}
    public func acquire(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active.count < 2 else { return false }
        active.insert(id); return true
    }
    public func release(_ id: UUID) { lock.lock(); defer { lock.unlock() }; active.remove(id) }
}

/// One XPC connection owns one Core. There is no API accepting a PID to kill.
public final class TunSession {
    private let lock = NSLock()
    private let logLock = NSLock()
    private let id = UUID()
    private let limiter: SlotLimiter
    private let prepare: (HelperRequest) throws -> PreparedLaunch
    private let launch: (PreparedLaunch, @escaping (String) -> Void) throws -> ManagedCore
    private let network: any ManagedTunNetwork
    private var cleanupFailure: String?
    private var core: ManagedCore?
    private var prepared: PreparedLaunch?
    private var state = "idle"
    private var forced = false
    private var logs: [String] = []
    private var logBytes = 0
    private let graceSeconds: TimeInterval

    public init(limiter: SlotLimiter, graceSeconds: TimeInterval = 8,
                network: any ManagedTunNetwork = TemporaryTunDNS(),
                prepare: @escaping (HelperRequest) throws -> PreparedLaunch,
                launch: @escaping (PreparedLaunch, @escaping (String) -> Void) throws -> ManagedCore = { try NativeCore($0, log: $1) }) {
        self.limiter = limiter; self.prepare = prepare; self.launch = launch; self.graceSeconds = graceSeconds
        self.network = network
    }

    public func handle(_ data: Data) -> HelperResponse {
        lock.lock(); defer { lock.unlock() }
        do {
            guard data.count <= 100 * 1024 * 1024 else { throw HelperFailure("request_too_large") }
            let request = try JSONDecoder().decode(HelperRequest.self, from: data)
            refreshExited()
            switch request.action {
            case "status": break
            case "start":
                guard core == nil else { throw HelperFailure("session_already_running") }
                guard limiter.acquire(id) else { throw HelperFailure("helper_busy") }
                do {
                    let prepared = try prepare(request)
                    self.prepared = prepared
                    core = try launch(prepared, { [weak self] in self?.appendLog($0) })
                    try network.install(prepared.tunDNS)
                    guard core?.isRunning == true else { throw HelperFailure("core_exited_during_start") }
                    state = "running"; forced = false; cleanupFailure = nil
                } catch {
                    stopLocked(); throw error
                }
            case "stop": stopLocked()
            default: throw HelperFailure("action_not_allowed")
            }
            return response()
        } catch {
            return HelperResponse(success: false,
                code: (error as? HelperFailure)?.description ?? "helper_operation_failed", state: state)
        }
    }

    public func disconnect() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        // Return DNS to macOS before its TUN resolver is stopped.
        do { try network.restore(); cleanupFailure = nil }
        catch { cleanupFailure = "tun_dns_cleanup_failed"; state = "faulted"; return }
        guard let core else { cleanup(); return }
        core.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + graceSeconds
        while core.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if core.isRunning {
            forced = true; core.forceKill()
            let killDeadline = ProcessInfo.processInfo.systemUptime + 2
            while core.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        if core.isRunning { state = "faulted"; return }
        state = forced ? "faulted" : "stopped"
        cleanup()
    }

    private func refreshExited() {
        if let core, !core.isRunning {
            state = core.exitCode == 0 && !forced ? "stopped" : "faulted"
            cleanup()
        }
    }

    private func cleanup() {
        do { try network.restore(); cleanupFailure = nil }
        catch { cleanupFailure = "tun_dns_cleanup_failed"; state = "faulted"; return }
        if let directory = prepared?.directory { try? FileManager.default.removeItem(at: directory) }
        prepared = nil; core = nil; limiter.release(id)
    }

    private func appendLog(_ text: String) {
        logLock.lock(); defer { logLock.unlock() }
        let entry = String(text.prefix(16_384))
        logs.append(entry); logBytes += entry.utf8.count
        while logs.count > 10_000 || logBytes > 1_000_000 {
            logBytes -= logs.removeFirst().utf8.count
        }
    }

    private func response() -> HelperResponse {
        var result = HelperResponse(success: state != "faulted", code: cleanupFailure ?? (forced ? "forced_stop_cleanup_unconfirmed" : (state == "faulted" ? "core_failed" : "ok")), state: state)
        result.pid = core?.pid
        result.executablePath = prepared?.executable.path
        result.forced = forced
        logLock.lock(); result.logs = logs; logs.removeAll(); logBytes = 0; logLock.unlock()
        return result
    }
}
