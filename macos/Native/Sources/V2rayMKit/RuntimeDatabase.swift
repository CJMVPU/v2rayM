import Foundation
import SQLite3

/// A short-lived connection sees the currently installed database after backup restore.
/// SQL is internal to the runtime. User data is passed exclusively through bindings.
final class RuntimeDatabase {
    enum Value: Hashable, Codable {
        case integer(Int64), real(Double), text(String), blob(Data), null
    }
    typealias Row = [String: Value]
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, writable: Bool = false, create: Bool = false) throws {
        var db: OpaquePointer?
        let mode = writable ? SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) : SQLITE_OPEN_READONLY
        let result = sqlite3_open_v2(url.path, &db, mode, nil)
        guard result == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ClientFailure("database_open_failed")
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
    }

    func backup(to destination: URL) throws {
        let copy = try RuntimeDatabase(url: destination, writable: true, create: true)
        guard let transfer = sqlite3_backup_init(copy.handle, "main", handle, "main") else {
            throw ClientFailure("backup_database_failed")
        }
        let status = sqlite3_backup_step(transfer, -1)
        let finished = sqlite3_backup_finish(transfer)
        guard status == SQLITE_DONE && finished == SQLITE_OK else { throw ClientFailure("backup_database_failed") }
        // The ZIP carries one database file. Force the snapshot out of WAL mode while
        // its writable connection is open so a read-only extractor never needs sidecars.
        let mode = try copy.query("PRAGMA journal_mode=DELETE")
        guard mode.first?["journal_mode"] == .text("delete") else { throw ClientFailure("backup_database_failed") }
    }

    deinit { sqlite3_close(handle) }

    func query(_ sql: String, _ parameters: [Value] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ClientFailure("database_prepare_failed")
        }
        defer { sqlite3_finalize(statement) }
        guard parameters.count == Int(sqlite3_bind_parameter_count(statement)) else {
            throw ClientFailure("database_parameters_invalid")
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let n): result = sqlite3_bind_int64(statement, index, n)
            case .real(let x): result = sqlite3_bind_double(statement, index, x)
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), Self.transient)
            case .blob(let data):
                if data.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
                else {
                    result = data.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                    }
                }
            }
            guard result == SQLITE_OK else { throw ClientFailure("database_bind_failed") }
        }
        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                var row: Row = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                    case SQLITE_TEXT:
                        let bytes = UnsafeBufferPointer(start: sqlite3_column_text(statement, index),
                                                        count: Int(sqlite3_column_bytes(statement, index)))
                        row[name] = .text(String(decoding: bytes, as: UTF8.self))
                    case SQLITE_BLOB:
                        let bytes = sqlite3_column_blob(statement, index)
                        row[name] = .blob(bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, index))) } ?? Data())
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            default: throw ClientFailure("database_operation_failed")
            }
        }
    }

    func transaction<T>(writable: Bool = true, _ work: () throws -> T) throws -> T {
        _ = try query(writable ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try work()
            _ = try query("COMMIT")
            return result
        } catch {
            _ = try? query("ROLLBACK")
            throw error
        }
    }
}

public actor NativeConfigurationStore {
    let databaseURL: URL

    public init(dataDirectory: URL) {
        databaseURL = dataDirectory.appendingPathComponent("guiConfigs/guiNDB.db")
    }

    public func prepareDatabase() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let db = try RuntimeDatabase(url: databaseURL, writable: true, create: true)
        try db.installSchema()
    }

    public func routingProfiles() throws -> [RoutingProfile] {
        let db = try RuntimeDatabase(url: databaseURL)
        return try db.query("SELECT Id, Remarks, IsActive FROM RoutingItem ORDER BY Sort").map { row in
            guard case let .text(id) = row["Id"] else { throw ClientFailure("routing_id_missing") }
            let name: String
            if case let .text(remarks) = row["Remarks"] { name = remarks } else { name = "" }
            return RoutingProfile(id: id, remarks: name, isActive: row["IsActive"] == .integer(1))
        }
    }

    public func profileDocument(id: String) throws -> SettingsValue {
        let db = try RuntimeDatabase(url: databaseURL)
        guard let row = try db.query("SELECT * FROM ProfileItem WHERE IndexId = ?", [.text(id)]).first else {
            throw ClientFailure("profile_not_found")
        }
        return Self.nodeDocument(from: row)
    }

    static func nodeDocument(from row: RuntimeDatabase.Row) -> SettingsValue {
        let types: [Int64: String] = [1: "vMess", 2: "custom", 3: "shadowsocks", 4: "socks", 5: "vless",
                                      6: "trojan", 7: "hysteria2", 8: "tuic", 9: "wireGuard", 10: "http",
                                      11: "anytls", 12: "naive", 13: "outbound", 14: "masque",
                                      101: "policyGroup", 102: "proxyChain"]
        var fields: [String: SettingsValue] = [:]
        for (column, value) in row {
            let key = column.prefix(1).lowercased() + column.dropFirst()
            switch value {
            case .null: fields[key] = .null
            case .text(let text): fields[key] = .string(text)
            case .integer(let number):
                if column == "ConfigType", let name = types[number] { fields[key] = .string(name) }
                else if column == "CoreType", number == 2 { fields[key] = .string("xray") }
                else if ["MuxEnabled", "DisplayLog", "IsSub"].contains(column) { fields[key] = .bool(number != 0) }
                else { fields[key] = Double(exactly: number).map(SettingsValue.number) ?? .integer64(number) }
            case .real(let number): fields[key] = .number(number)
            case .blob: continue // Unexposed opaque fields stay in the original row.
            }
        }
        return .object(fields)
    }
}
