import Darwin
import Foundation
import TunShared

/// Go installs process-wide runtime handlers. The successfully loaded image must stay
/// mapped after a proxy session closes; individual sessions can be stopped and restarted.
public actor EmbeddedXray {
    private typealias Version = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias ValidateGeo = @convention(c) (UnsafePointer<UInt8>?, Int, Int32) -> UnsafeMutablePointer<CChar>?
    private typealias Start = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafePointer<CChar>, Int32, Int32) -> UnsafeMutablePointer<CChar>?
    private typealias Stop = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias OpenProbe = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    private typealias MeasureProbe = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    private typealias CloseProbe = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    private typealias Release = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
    private typealias ReadTraffic = @convention(c) (UnsafeMutablePointer<Int64>, Int32) -> Int32
    private let readTraffic: ReadTraffic
    private let drain: Version
    private let validateGeo: ValidateGeo
    private let startInstance: Start
    private let stopInstance: Stop
    private let openProbe: OpenProbe
    private let measureProbe: MeasureProbe
    private let closeProbe: CloseProbe
    private let release: Release
    public nonisolated let version: String
    private var owner: UUID?
    public var running: Bool { owner != nil }
    public nonisolated var displayVersion: String? {
        Self.displayVersion(version)
    }
    private nonisolated static func displayVersion(_ version: String) -> String? {
        let fields = version.split(whereSeparator: { $0.isWhitespace })
        guard fields.count > 1, fields[0] == "Xray",
              fields[1].wholeMatch(of: #/[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?/#) != nil else { return nil }
        var version = String(fields[1])
        if fields.contains(where: { $0.hasSuffix("-v2raym-darwin-bind2") }) { version += "（修复版 M2）" }
        else if fields.contains(where: { $0.hasSuffix("-v2raym-darwin-bind1") }) { version += "（修复版 M1）" }
        return version
    }
    /// The signed resource is produced alongside the library from the same pinned inputs.
    /// Reading it does not initialize Go. Actual use still requires loading every ABI symbol.
    nonisolated static func bundledVersion(in bundle: URL) -> String? {
        struct Receipt: Decodable {
            struct Inputs: Decodable { let version: String; let buildMarker: String }
            let inputs: Inputs
        }
        let path = bundle.appendingPathComponent("Contents/Frameworks/libV2rayMXray.dylib")
        let receipt = bundle.appendingPathComponent("Contents/Resources/Xray/library-build.json")
        guard (try? path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: path.path),
              let data = try? Data(contentsOf: receipt),
              let inputs = try? JSONDecoder().decode(Receipt.self, from: data).inputs else { return nil }
        return displayVersion("Xray " + inputs.version + " " + inputs.buildMarker)
    }

    func trafficKiB(for session: UUID) -> [Int64]? {
        guard owner == session else { return nil }
        var counts = [Int64](repeating: 0, count: 4)
        let ok = counts.withUnsafeMutableBufferPointer { buffer in readTraffic(buffer.baseAddress!, Int32(buffer.count)) }
        return ok == 1 ? counts.map { $0 / 1024 } : nil
    }

    // The pinned core includes the entire PSK list in this diagnostic. Discard that
    // diagnostic even for file-backed configurations, including embedded newlines.
    nonisolated static func safeDiagnostic(_ message: String) -> String {
        if message.contains("shadowsocks_2022: invalid key:") { return "Shadowsocks 2022 密钥格式或长度无效。" }
        return message
    }

    func drainLogs() -> [String] {
        guard let result = drain() else { return [] }
        defer { release(result) }
        let bytes = Data(bytes: result, count: strlen(result))
        return ((try? JSONDecoder().decode([String].self, from: bytes)) ?? []).map(Self.safeDiagnostic)
    }

    public init(bundle: URL) throws {
        let url = bundle.appendingPathComponent("Contents/Frameworks/libV2rayMXray.dylib")
        guard let image = dlopen(url.path, RTLD_LOCAL | RTLD_NOW) else { throw ClientFailure("core_library_missing") }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let address = dlsym(image, name) else { throw ClientFailure("core_library_invalid") }
            return unsafeBitCast(address, to: type)
        }
        let versionFunction = try symbol("V2rayMCoreVersion", Version.self)
        validateGeo = try symbol("V2rayMCoreValidateGeo", ValidateGeo.self)
        readTraffic = try symbol("V2rayMCoreTraffic", ReadTraffic.self)
        drain = try symbol("V2rayMCoreDrainLogs", Version.self)
        startInstance = try symbol("V2rayMCoreStartLogged", Start.self)
        stopInstance = try symbol("V2rayMCoreStop", Stop.self)
        openProbe = try symbol("V2rayMCoreOpenProbe", OpenProbe.self)
        measureProbe = try symbol("V2rayMCoreMeasureProbe", MeasureProbe.self)
        closeProbe = try symbol("V2rayMCoreCloseProbe", CloseProbe.self)
        release = try symbol("V2rayMCoreFree", Release.self)
        guard let result = versionFunction() else { throw ClientFailure("core_library_invalid") }
        version = String(cString: result)
        release(result)
    }

    func validateGeoDirectory(_ directory: URL) throws {
        for name in NativeGeoAssets.names {
            try Task.checkCancellation()
            let file = directory.appendingPathComponent(name + ".dat")
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard (1...HelperContract.resourceBytes).contains(bytes.count) else { throw ClientFailure("geo_file_invalid") }
            let error = bytes.withUnsafeBytes { buffer in
                validateGeo(buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count, name == "geosite" ? 1 : 0)
            }
            if let error {
                defer { release(error) }
                throw ClientFailure("geo_file_invalid", String(cString: error))
            }
        }
        try Task.checkCancellation()
    }

    public func start(config: SettingsValue, assets: URL, tunnel: FileHandle? = nil, sessionID: UUID = UUID(), custom: SettingsValue? = nil, displayLogs: Bool = true) throws {
        guard !running else { throw ClientFailure("operation_in_progress") }
        let error: UnsafeMutablePointer<CChar>?
        if let custom {
            guard tunnel == nil else { throw ClientFailure("mac_tun_generated_core_required") }
            error = startInstance(try config.json(), try custom.json(), assets.path, -1, displayLogs ? 1 : 0)
        } else {
            error = startInstance(try config.json(), nil, assets.path, tunnel?.fileDescriptor ?? -1, displayLogs ? 1 : 0)
        }
        if let error {
            defer { release(error) }
            throw ClientFailure("core_start_failed", Self.safeDiagnostic(String(cString: error)))
        }
        owner = sessionID
    }

    func stop(ifOwnedBy id: UUID) throws {
        if owner == id { try stop() }
    }

    func measure(id: UUID, configuration: SettingsValue, assets: URL, request: SettingsValue) async throws -> SettingsValue {
        let key = id.uuidString, input = try request.json()
        try Task.checkCancellation()
        if let error = openProbe(key, try configuration.json(), assets.path) {
            defer { release(error) }
            throw ClientFailure("speedtest_invalid_profile", Self.safeDiagnostic(String(cString: error)))
        }
        // The Go call can block in a network read. Keep both the actor and Swift's
        // cooperative executors available for mode switches and cancellation.
        let measure = measureProbe, close = closeProbe, free = release
        let output: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let bytes = measure(key, input) else { continuation.resume(returning: nil); return }
                    let value = String(cString: bytes)
                    free(bytes)
                    continuation.resume(returning: value)
                }
            }
        } onCancel: {
            DispatchQueue.global(qos: .utility).async { if let error = close(key) { free(error) } }
        }
        if let error = close(key) {
            defer { free(error) }
            throw ClientFailure("speedtest_stop_failed", String(cString: error))
        }
        try Task.checkCancellation()
        guard let output else { return .object(["delay": .number(-1)]) }
        return try SettingsValue.parse(output)
    }

    public func stop() throws {
        guard running else { return }
        if let error = stopInstance() {
            defer { release(error) }
            throw ClientFailure("core_stop_failed", String(cString: error))
        }
        owner = nil
    }
}
