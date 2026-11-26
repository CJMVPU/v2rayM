import CryptoKit
import Darwin
import Foundation

/// Imported file-backed profiles use the same relative JSON filenames that older v2rayM releases read.
enum FileProfileImport {
    private static let pending = "__nativeImportDocument"
    private static let protocols = Set(["block","blackhole","loopback","direct","freedom","http","shadowsocks","socks","vless","vmess","trojan","hysteria","masque","dns","wireguard"])
    private static let prefix = "v2raym-import-"

    static func isFile(_ row: RuntimeDatabase.Row) -> Bool {
        row["ConfigType"] == .integer(2) || row["ConfigType"] == .integer(13)
    }

    static func decode(_ text: String, subscriptionName: String?) throws -> [RuntimeDatabase.Row] {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let value = try decoder.decode(SettingsValue.self, from: Data(text.utf8))
        if let rows = try ShareLinkImport.sip008(value) { return rows }
        func visit(_ input: SettingsValue) throws -> [RuntimeDatabase.Row] {
            if case .array(let items) = input { return try items.flatMap(visit) }
            guard case .object = input else { throw ClientFailure("profile_config_file_invalid") }
            let members = input["outbounds"].items
            if case .array = input["inbounds"], members.contains(where: isOutbound) {
                guard members.allSatisfy({ protocols.contains($0["protocol"].text.lowercased()) }) else { throw ClientFailure("outbound_unsupported") }
                let name = input["remarks"].text
                return [try record(input, full: true, name: name.isEmpty ? (subscriptionName ?? "v2ray_custom") : name)]
            }
            if case .array = input["outbounds"] {
                let rows = try members.compactMap { try standalone($0) }
                guard !rows.isEmpty else { throw ClientFailure("share_format_unsupported") }
                return rows
            }
            guard let row = try standalone(input) else { throw ClientFailure("share_format_unsupported") }
            return [row]
        }
        let rows = try visit(value)
        guard !rows.isEmpty else { throw ClientFailure("profile_import_empty") }
        return rows
    }

    private static func isOutbound(_ value: SettingsValue) -> Bool {
        guard case .object = value, !value["protocol"].text.isEmpty else { return false }
        return ["tag","settings","streamSettings","mux"].filter {
            switch value[$0] { case .null, .string(""): return false; default: return true }
        }.count >= 2
    }

    static func standalone(_ value: SettingsValue) throws -> RuntimeDatabase.Row? {
        let kind = value["protocol"].text
        guard protocols.contains(kind.lowercased()) else { throw ClientFailure("outbound_unsupported") }
        guard isOutbound(value), !["freedom","blackhole","dns","loopback"].contains(kind) else { return nil }
        return try record(value, full: false, name: kind + "_" + value["tag"].text)
    }

    private static func record(_ value: SettingsValue, full: Bool, name: String) throws -> RuntimeDatabase.Row {
        ["ConfigVersion": .integer(4), "ConfigType": .integer(full ? 2 : 13), "CoreType": .integer(2),
         "Remarks": .text(name), "DisplayLog": .integer(1), pending: .text(try value.json())]
    }

    /// Arrays are a single CustomOutbound only inside a typed inner URI or an existing profile file.
    /// Untyped JSON arrays remain import batches.
    static func customMembers(_ value: SettingsValue) throws -> [SettingsValue] {
        let members: [SettingsValue]
        if case let .array(values) = value { members = values } else { members = [value] }
        guard !members.isEmpty else { throw ClientFailure("profile_config_file_invalid") }
        var tags = Set<String>()
        for member in members {
            guard case .object = member, protocols.contains(member["protocol"].text.lowercased()) else {
                throw ClientFailure("profile_config_file_invalid")
            }
            let tag = member["tag"]
            if tag == .null { continue }
            guard case let .string(name) = tag, name.isEmpty || tags.insert(name).inserted else {
                throw ClientFailure("profile_config_file_invalid")
            }
        }
        return members
    }

    static func attachOutbound(_ value: SettingsValue, to row: inout RuntimeDatabase.Row) throws {
        _ = try customMembers(value)
        row["Address"] = nil
        row[pending] = .text(try value.json())
    }

    static func materialize(_ row: inout RuntimeDatabase.Row, directory: URL) throws {
        guard isFile(row) else { return }
        guard case .text(let json) = row.removeValue(forKey: pending) else { throw ClientFailure("profile_config_file_invalid") }
        row["Address"] = .text(try install(Data(json.utf8), in: directory))
    }

    /// Store exact bytes; old JSON5 files, comments and signatures survive backup.
    static func install(_ data: Data, in directory: URL) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = prefix + digest + ".json"
        let url = directory.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } else {
            guard errno == EEXIST else { throw ClientFailure("profile_import_file_failed") }
            let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard info.isSymbolicLink == false, info.isRegularFile == true, info.fileSize == data.count,
                  try Data(contentsOf: url, options: .mappedIfSafe) == data else { throw ClientFailure("profile_import_file_conflict") }
        }
        return name
    }

    /// A failed transaction may have created files just before SQLite rolled back. Check
    /// reachability under the same writer lock as import before removing any generated file.
    static func prune(_ directory: URL, db: RuntimeDatabase) throws {
        try db.transaction {
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            let candidates = files.filter { $0.lastPathComponent.wholeMatch(of: #/v2raym-import-[0-9a-f]{64}\.json/#) != nil }
            guard !candidates.isEmpty else { return }
            let names = try db.query("SELECT DISTINCT Address FROM ProfileItem WHERE ConfigType IN (2,13)")
            let referenced = Set(names.compactMap { row -> String? in
                guard case .text(let name) = row["Address"], !name.isEmpty else { return nil }
                return URL(fileURLWithPath: name, relativeTo: directory.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path
            })
            for file in candidates where !referenced.contains(file.resolvingSymlinksInPath().path) {
                let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard info.isSymbolicLink != true, info.isRegularFile == true else { continue }
                try fm.removeItem(at: file)
            }
        }
    }
}
