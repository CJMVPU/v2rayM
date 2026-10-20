import Foundation
import Darwin

public struct PreparedLaunch {
    public let directory: URL
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
}

public struct LaunchPolicy {
    public let bundle: URL
    public let stateRoot: URL
    private let validate: (URL, String) throws -> Void

    public init(bundle: URL, stateRoot: URL, validate: @escaping (URL, String) throws -> Void) {
        self.bundle = bundle; self.stateRoot = stateRoot; self.validate = validate
    }

    public func prepare(_ request: HelperRequest) throws -> PreparedLaunch {
        guard let kind = request.core, ["sing_box", "xray"].contains(kind),
              let data = request.config, !data.isEmpty, data.count <= 4 * 1024 * 1024,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = object["inbounds"] as? [[String: Any]],
              inbounds.contains(where: { ($0[kind == "xray" ? "protocol" : "type"] as? String) == "tun" }) else {
            throw HelperFailure("generated_tun_config_required")
        }
        let resources = request.resources ?? [:]
        guard resources.count <= 128,
              resources.values.reduce(0, { $0 + $1.count }) <= 64 * 1024 * 1024,
              resources.allSatisfy({ validResourceName($0.key) && $0.value.count <= 32 * 1024 * 1024 }),
              (request.paths ?? [:]).values.allSatisfy({ resources[$0] != nil }) else {
            throw HelperFailure("resource_snapshot_invalid")
        }
        try ensurePrivateRoot()
        let directory = stateRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let name = kind == "xray" ? "xray" : "sing-box"
            let source = bundle.appendingPathComponent("Contents/Resources/Backend/bin/\(kind)/\(name)")
            let executable = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: executable)
            let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw HelperFailure("core_must_be_regular_file")
            }
            // Verify the private copy actually executed, closing the user-writable bundle race.
            try validate(executable, kind)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            for (name, bytes) in resources {
                let target = directory.appendingPathComponent(name)
                try bytes.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            let originalLog = object["log"] as? [String: Any] ?? [:]
            object["log"] = kind == "xray"
                ? ["loglevel": originalLog["loglevel"] as? String ?? "warning"]
                : ["level": originalLog["level"] as? String ?? "warn", "timestamp": true]
            if var experimental = object["experimental"] as? [String: Any] {
                experimental.removeValue(forKey: "cache_file")
                if var clash = experimental["clash_api"] as? [String: Any] {
                    clash.removeValue(forKey: "external_ui")
                    clash.removeValue(forKey: "external_ui_download_url")
                    experimental["clash_api"] = clash
                }
                object["experimental"] = experimental
            }
            let transformed = try rewrite(object, mappings: request.paths ?? [:], directory: directory)
            let config = directory.appendingPathComponent("config.json")
            try JSONSerialization.data(withJSONObject: transformed, options: [.sortedKeys]).write(to: config)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            return PreparedLaunch(directory: directory, executable: executable,
                arguments: ["run", kind == "xray" ? "-config" : "-c", config.path] + (kind == "sing_box" ? ["--disable-color"] : []),
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "XRAY_LOCATION_ASSET": directory.path, "XRAY_LOCATION_CERT": directory.path])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
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
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,120}\\.(dat|srs|pem|crt|key)$", options: .regularExpression) != nil
            && !name.contains("..")
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
