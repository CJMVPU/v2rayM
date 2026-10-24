import Foundation
import Darwin

public struct PreparedLaunch {
    public let directory: URL
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public var tunDNS: TunDNSSettings? = nil
}

public struct LaunchPolicy {
    public let bundle: URL
    public let stateRoot: URL
    private let validate: (URL, String) throws -> Void
    private let verifiedCore: ((String) throws -> VerifiedCoreSource?)?

    public init(bundle: URL, stateRoot: URL, validate: @escaping (URL, String) throws -> Void,
                verifiedCore: ((String) throws -> VerifiedCoreSource?)? = nil) {
        self.bundle = bundle; self.stateRoot = stateRoot; self.validate = validate
        self.verifiedCore = verifiedCore
    }

    public func prepare(_ request: HelperRequest) throws -> PreparedLaunch {
        guard let kind = request.core, kind == "xray",
              let data = request.config, !data.isEmpty, data.count <= HelperContract.configBytes,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = object["inbounds"] as? [[String: Any]],
              inbounds.contains(where: { ($0["protocol"] as? String) == "tun" }) else {
            throw HelperFailure("generated_tun_config_required")
        }
        var dns: TunDNSSettings?
        do {
            var nativeInbounds = inbounds
            for index in nativeInbounds.indices where nativeInbounds[index]["protocol"] as? String == "tun" {
                var settings = nativeInbounds[index]["settings"] as? [String: Any] ?? [:]
                let requested = settings["name"] as? String ?? ""
                let valid = requested.range(of: "^utun[0-9]{1,4}$", options: .regularExpression) != nil
                let interface = valid && if_nametoindex(requested) == 0 ? requested : try availableInterface()
                settings["name"] = interface
                // Bind the core's own outbound sockets to the physical uplink to avoid loops.
                if settings["autoOutboundsInterface"] == nil { settings["autoOutboundsInterface"] = "auto" }
                nativeInbounds[index]["settings"] = settings
                if request.configureSystemDNS == true {
                    guard dns == nil, let gateway = (settings["gateway"] as? [String])?.first,
                          let resolver = gateway.split(separator: "/").first.map(String.init),
                          validIPv4(resolver) else { throw HelperFailure("native_tun_dns_gateway_required") }
                    dns = TunDNSSettings(interface: interface, resolver: resolver)
                }
            }
            object["inbounds"] = nativeInbounds
        }
        let resources = request.resources ?? [:]
        guard resources.count <= HelperContract.resourceCount,
              resources.values.reduce(0, { $0 + $1.count }) <= HelperContract.resourcesBytes,
              resources.allSatisfy({ validResourceName($0.key) && $0.value.count <= HelperContract.resourceBytes }),
              (request.paths ?? [:]).values.allSatisfy({ resources[$0] != nil }) else {
            throw HelperFailure("resource_snapshot_invalid")
        }
        try ensurePrivateRoot()
        let directory = stateRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let name = "xray"
            let approved = try verifiedCore?(kind)
            let source = approved?.url ?? bundle.appendingPathComponent("Contents/Resources/Backend/bin/\(kind)/\(name)")
            let executable = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: executable)
            let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw HelperFailure("core_must_be_regular_file")
            }
            // Verify the private copy actually executed, closing the user-writable bundle race.
            if let approved {
                guard OfficialCorePolicy.hash(try Data(contentsOf: executable)) == approved.sha256 else {
                    throw HelperFailure("installed_core_digest_mismatch")
                }
            } else { try validate(executable, kind) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            for (name, bytes) in resources {
                let target = directory.appendingPathComponent(name)
                try bytes.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            let originalLog = object["log"] as? [String: Any] ?? [:]
            object["log"] = ["loglevel": originalLog["loglevel"] as? String ?? "warning"]
            let transformed = try rewrite(object, mappings: request.paths ?? [:], directory: directory)
            let config = directory.appendingPathComponent("config.json")
            try JSONSerialization.data(withJSONObject: transformed, options: [.sortedKeys]).write(to: config)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            return PreparedLaunch(directory: directory, executable: executable,
                arguments: ["run", "-config", config.path],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "XRAY_LOCATION_ASSET": directory.path, "XRAY_LOCATION_CERT": directory.path], tunDNS: dns)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func availableInterface() throws -> String {
        for number in (100...1023).shuffled() {
            let name = "utun\(number)"
            if if_nametoindex(name) == 0 { return name }
        }
        throw HelperFailure("native_tun_interface_unavailable")
    }
    private func validIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, value, &address) == 1 && value != "0.0.0.0" && value != "127.0.0.1"
    }

    private func ensurePrivateRoot() throws {
        var info = stat()
        if lstat(stateRoot.path, &info) != 0 {
            guard errno == ENOENT else { throw HelperFailure("state_directory_unavailable") }
            try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(stateRoot.path, &info) == 0 else { throw HelperFailure("state_directory_unavailable") }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw HelperFailure("state_directory_not_private")
        }
    }

    private func validResourceName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,120}\\.[A-Za-z0-9]+$", options: .regularExpression) != nil
            && !name.contains("..") && HelperContract.resourceExtensions.contains(URL(fileURLWithPath: name).pathExtension)
    }

    private func rewrite(_ value: Any, mappings: [String: String], directory: URL, parent: String = "") throws -> Any {
        if let array = value as? [Any] { return try array.map { try rewrite($0, mappings: mappings, directory: directory, parent: parent) } }
        guard let object = value as? [String: Any] else { return value }
        var output: [String: Any] = [:]
        let transportTypes = ["ws", "websocket", "http", "https", "httpupgrade", "grpc", "masque"]
        let isTransportPath = transportTypes.contains(object["type"] as? String ?? "")
            || ["wsSettings", "httpSettings", "httpupgradeSettings", "grpcSettings", "xhttpSettings"].contains(parent)
        for (key, item) in object {
            let normalized = key.replacingOccurrences(of: "_", with: "").lowercased()
            if ["include", "externalui", "externalcontrollerunix", "oninterfaceupdate"].contains(normalized) {
                throw HelperFailure("privileged_config_field_not_allowed")
            }
            let isFile = ["certificatepath", "keypath", "certificatefile", "keyfile", "cafile", "sslkeylog"].contains(normalized)
                || (key == "path" && !isTransportPath)
            if isFile {
                guard let original = item as? String, let relative = mappings[original] else {
                    throw HelperFailure("local_file_must_be_snapshotted")
                }
                output[key] = directory.appendingPathComponent(relative).path
            } else {
                output[key] = try rewrite(item, mappings: mappings, directory: directory, parent: key)
            }
        }
        return output
    }
}
