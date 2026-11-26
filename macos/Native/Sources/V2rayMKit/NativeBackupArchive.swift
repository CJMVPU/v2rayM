import CSystemArchive
import Darwin
import Foundation

enum NativeBackupArchive {
    static let limit = 64 * 1024 * 1024
    static let expandedLimit = 256 * 1024 * 1024
    static let entryLimit = 2048
    static let settings = "guiNConfig.json"
    static let database = "guiNDB.db"

    static func privateDirectory(_ location: URL) throws {
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func excluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("webapi-auth.json") || lower == "web-auth.json" || lower == "native-pending-edit.json"
            || lower == ".native-restore-id" || ["-wal", "-shm", "-journal"].contains { lower == database.lowercased() + $0 }
    }

    static func extract(_ file: URL, to directory: URL) throws {
        let invalid = ClientFailure("backup_archive_invalid")
        let properties = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              (1...limit).contains(properties.fileSize ?? 0), let reader = archive_read_new() else { throw invalid }
        defer { archive_read_free(reader) }
        guard archive_read_support_format_zip_seekable(reader) == 0,
              archive_read_open_filename(reader, file.path, 64 * 1024) == 0 else { throw invalid }
        try privateDirectory(directory)
        var names = Set<String>(), total: Int64 = 0, count = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == 1 { break } // ARCHIVE_EOF
            count += 1
            guard status == 0, let entry, count <= entryLimit,
                  let raw = archive_entry_pathname(entry), let path = String(validatingUTF8: raw),
                  archive_entry_is_encrypted(entry) == 0, archive_entry_hardlink(entry) == nil,
                  archive_entry_symlink(entry) == nil else { throw invalid }
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            let parts = normalized.split(separator: "/").map(String.init)
            guard !normalized.hasPrefix("/"), !normalized.contains(":"), !parts.isEmpty,
                  !parts.contains("."), !parts.contains("..") else { throw invalid }
            let size = archive_entry_size(entry)
            guard (0...Int64(expandedLimit) - total).contains(size) else { throw invalid }
            total += size
            let kind = archive_entry_filetype(entry)
            if kind == S_IFDIR && size == 0 { continue }
            guard kind == S_IFREG, parts.count >= 2, parts.dropLast().last == "guiConfigs",
                  let name = parts.last, names.insert(name.lowercased()).inserted else { throw invalid }
            let destination = directory.appendingPathComponent(name)
            // SQLite can rebuild SHM, but committed transactions may exist only in a WAL.
            let keep = !excluded(name) || name.caseInsensitiveCompare(database + "-wal") == .orderedSame
            var output: FileHandle?
            if keep {
                let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw invalid }
                output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            }
            defer { try? output?.close() }
            var written: Int64 = 0
            while true {
                let n = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                guard n >= 0, Int64(n) <= size - written else { throw invalid }
                if n == 0 { break }
                if let output { try output.write(contentsOf: Data(buffer.prefix(n))) }
                written += Int64(n)
            }
            guard written == size else { throw invalid }
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(settings).path) else { throw invalid }
    }

    static func create(from directory: URL, at archive: URL, scratch: URL, forLocalRollback: Bool = false) throws {
        let fm = FileManager.default
        let snapshot = scratch.appendingPathComponent("guiConfigs")
        try privateDirectory(snapshot)
        defer { try? fm.removeItem(at: snapshot) }
        var count = 1, total = 0
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]) {
            let name = file.lastPathComponent
            if excluded(name) || name.caseInsensitiveCompare(database) == .orderedSame { continue }
            let properties = try file.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            if properties.isRegularFile != true || properties.isSymbolicLink == true { continue }
            guard !name.hasPrefix("."), !name.contains(":"), !name.contains("\\") else { continue }
            guard let size = properties.fileSize, size <= expandedLimit - total else { throw ClientFailure("backup_archive_too_large") }
            total += size
            count += 1
            guard count < entryLimit else { throw ClientFailure("backup_archive_too_large") }
            try fm.copyItem(at: file, to: snapshot.appendingPathComponent(name))
        }
        let file = directory.appendingPathComponent(database)
        if fm.fileExists(atPath: file.path) {
            let copy = snapshot.appendingPathComponent(database)
            try RuntimeDatabase(url: file).backup(to: copy)
            try collectProfileFiles(in: directory, snapshot: snapshot, backupDB: copy,
                                    total: &total, count: &count, forLocalRollback: forLocalRollback)
            let size = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? expandedLimit
            guard size <= expandedLimit - total else { throw ClientFailure("backup_archive_too_large") }
        }
        guard !fm.fileExists(atPath: archive.path), fm.fileExists(atPath: snapshot.appendingPathComponent(settings).path) else {
            throw ClientFailure("backup_create_failed")
        }
        let failure = ClientFailure("backup_create_failed")
        let fd = open(archive.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? fm.removeItem(at: archive) }
        }
        guard let writer = archive_write_new() else { throw failure }
        defer { archive_write_free(writer) }
        guard archive_write_set_format_zip(writer) == 0, archive_write_open_fd(writer, fd) == 0 else { throw failure }
        for file in try fm.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: [.fileSizeKey]) {
            try Task.checkCancellation()
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  let entry = archive_entry_new() else { throw failure }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, "guiConfigs/" + file.lastPathComponent)
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_perm(entry, 0o600)
            archive_entry_set_size(entry, Int64(size))
            guard archive_write_header(writer, entry) == 0 else { throw failure }
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var written = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                let count = chunk.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                guard count == chunk.count else { throw failure }
                written += count
            }
            guard written == size, archive_write_finish_entry(writer) == 0 else { throw failure }
        }
        guard archive_write_close(writer) == 0 else { throw failure }
        try output.synchronize()
        guard (1...limit).contains(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) else {
            throw ClientFailure("backup_archive_too_large")
        }
        complete = true
    }

    /// Older versions also accepted nested and absolute addresses. Rewrite only the
    /// snapshot DB so it can be restored elsewhere using the existing flat ZIP format.
    private static func collectProfileFiles(in directory: URL, snapshot: URL, backupDB: URL,
                                            total: inout Int, count: inout Int, forLocalRollback: Bool) throws {
        let fm = FileManager.default
        let db = try RuntimeDatabase(url: backupDB, writable: true)
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var included = Set(try fm.contentsOfDirectory(atPath: snapshot.path))
        try db.transaction {
            // An older or partially initialized database may contain settings tables only.
            let columns = try db.query("PRAGMA table_info(ProfileItem)").compactMap { row -> String? in
                guard case let .text(name) = row["name"] else { return nil }
                return name.lowercased()
            }
            guard columns.contains("address"), columns.contains("configtype") else { return }
            let rows = try db.query("SELECT DISTINCT Address FROM ProfileItem WHERE ConfigType IN (2,13)")
            for row in rows {
                try Task.checkCancellation()
                guard case let .text(address) = row["Address"], !address.isEmpty else {
                    if forLocalRollback { continue }
                    throw ClientFailure("backup_profile_file_missing", "自定义节点缺少配置文件地址。")
                }
                let file = URL(fileURLWithPath: address, relativeTo: directory.appendingPathComponent("", isDirectory: true))
                    .standardizedFileURL.resolvingSymlinksInPath()
                let parts = file.pathComponents.dropFirst(root.pathComponents.count)
                guard file.pathComponents.starts(with: root.pathComponents), !parts.isEmpty,
                      parts.allSatisfy({ !$0.hasPrefix(".") && !excluded($0) }),
                      file.lastPathComponent.caseInsensitiveCompare(database) != .orderedSame,
                      file.lastPathComponent.caseInsensitiveCompare(settings) != .orderedSame else {
                    if forLocalRollback { continue }
                    throw ClientFailure("backup_profile_file_external", "自定义节点引用配置目录之外或受保护的文件。请先将它重新导入节点，再备份。")
                }
                let name: String
                if parts.count == 1, included.contains(file.lastPathComponent) {
                    name = file.lastPathComponent
                } else {
                    guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          info.isRegularFile == true, let size = info.fileSize else {
                        if forLocalRollback { continue }
                        throw ClientFailure("backup_profile_file_missing", "自定义节点引用的配置文件不存在或不可读。")
                    }
                    guard size <= expandedLimit else { throw ClientFailure("backup_archive_too_large") }
                    let data = try Data(contentsOf: file, options: .mappedIfSafe)
                    name = try FileProfileImport.install(data, in: snapshot)
                    if included.insert(name).inserted {
                        guard data.count <= expandedLimit - total, count + 1 < entryLimit else { throw ClientFailure("backup_archive_too_large") }
                        total += data.count
                        count += 1
                    }
                }
                if name != address {
                    _ = try db.query("UPDATE ProfileItem SET Address=? WHERE ConfigType IN (2,13) AND Address=?", [.text(name), .text(address)])
                }
            }
        }
    }

    /// The caller owns this freshly extracted directory. Never open an archived SHM or
    /// install a WAL next to the live database. Compare SQLite's checksum-verified frame
    /// count with the commit markers so an invalid tail cannot quietly lose transactions.
    static func normalizeDatabase(in directory: URL) throws {
        let file = directory.appendingPathComponent(database)
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            if fm.fileExists(atPath: wal.path) { throw ClientFailure("backup_database_incompatible") }
            return
        }
        do {
            let pending = try fm.fileExists(atPath: wal.path) ? walCommit(at: wal) : nil
            let db = try RuntimeDatabase(url: file, writable: true)
            if let pending {
                let pageSize = try db.query("PRAGMA page_size").first?["page_size"]
                guard pageSize == .integer(pending.pageSize) else { throw ClientFailure("backup_database_incompatible") }
                let result = try db.query("PRAGMA wal_checkpoint(FULL)").first
                guard result?["busy"] == .integer(0), result?["log"] == .integer(pending.frames),
                      result?["checkpointed"] == .integer(pending.frames) else { throw ClientFailure("backup_database_incompatible") }
            }
            guard try db.query("PRAGMA journal_mode=DELETE").first?["journal_mode"] == .text("delete") else {
                throw ClientFailure("backup_database_incompatible")
            }
        } catch { throw ClientFailure("backup_database_incompatible") }
        // Empty sidecars are possible even with a DELETE-mode database from another writer.
        for sidecar in [wal, URL(fileURLWithPath: file.path + "-shm")] where fm.fileExists(atPath: sidecar.path) {
            try fm.removeItem(at: sidecar)
        }
        try checkDatabase(file)
    }

    private static func walCommit(at url: URL) throws -> (pageSize: Int64, frames: Int64)? {
        let wal = try Data(contentsOf: url, options: .mappedIfSafe)
        if wal.isEmpty { return nil }
        let invalid = ClientFailure("backup_database_incompatible")
        guard wal.count >= 32 else { throw invalid }
        func word(_ offset: Int) -> UInt32 {
            wal.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        let pageSize = word(8)
        guard [0x377f0682, 0x377f0683].contains(word(0)), word(4) == 3007000,
              (512...65536).contains(pageSize), pageSize.nonzeroBitCount == 1 else { throw invalid }
        let stride = 24 + Int(pageSize)
        guard (wal.count - 32).isMultiple(of: stride) else { throw invalid }
        let salt1 = word(16), salt2 = word(20)
        var committed: Int64 = 0
        for i in 0..<(wal.count - 32) / stride {
            let frame = 32 + i * stride
            // Recycled WALs may still contain trailing frames from an older generation.
            if word(frame + 8) != salt1 || word(frame + 12) != salt2 { break }
            if word(frame + 4) != 0 { committed = Int64(i + 1) }
        }
        return (Int64(pageSize), committed)
    }

    static func checkDatabase(_ file: URL) throws {
        do {
            let db = try RuntimeDatabase(url: file)
            let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'")
            let existing = Set(tables.compactMap { row -> String? in
                if case .text(let name) = row["name"] { return name.lowercased() }
                return nil
            })
            let known = ["DNSItem":"Id", "FullConfigTemplateItem":"Id", "ProfileExItem":"IndexId", "ProfileGroupItem":"IndexId",
                         "ProfileItem":"IndexId", "RoutingItem":"Id", "ServerStatItem":"IndexId", "SubItem":"Id"]
            guard try db.query("PRAGMA quick_check") == [["quick_check": .text("ok")]],
                  known.keys.contains(where: { existing.contains($0.lowercased()) }) else { throw ClientFailure("backup_database_incompatible") }
            for (table, pk) in known where existing.contains(table.lowercased()) {
                let columns = try db.query("PRAGMA table_info(" + table + ")")
                guard columns.contains(where: { $0["pk"] == .integer(1) && $0["name"] == .text(pk) }) else {
                    throw ClientFailure("backup_database_incompatible")
                }
            }
        } catch { throw ClientFailure("backup_database_incompatible") }
    }
}
