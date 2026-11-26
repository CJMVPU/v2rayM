import Darwin
import Foundation

struct NativeBackupRestore {
    let data: URL
    let fm = FileManager.default
    var current: URL { data.appendingPathComponent("guiConfigs") }
    var staging: URL { data.appendingPathComponent("guiTemps/native-restore") }
    var candidate: URL { staging.appendingPathComponent("guiConfigs") }
    private var markerName: String { ".native-restore-id" }
    private var journal: URL { data.appendingPathComponent("native-pending-restore.json") }
    struct Intent: Codable { let id: UUID; let runningNode: String? }

    func readIntent() throws -> Intent? {
        guard fm.fileExists(atPath: journal.path) else { return nil }
        return try JSONDecoder().decode(Intent.self, from: Data(contentsOf: journal))
    }

    func cleanup() throws {
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
    }

    func prepare(_ archive: URL) throws {
        guard try readIntent() == nil else { throw ClientFailure("backup_restore_pending") }
        try cleanup()
        let extracted = staging.appendingPathComponent("incoming")
        try NativeBackupArchive.extract(archive, to: extracted)
        let settings = extracted.appendingPathComponent(NativeBackupArchive.settings)
        guard let document = try? JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: settings)),
              case .object = document else { throw ClientFailure("backup_archive_invalid") }
        try NativeBackupArchive.normalizeDatabase(in: extracted)
    }

    /// Capture the current directory only after the old sampler/SQLite writers have stopped.
    func buildCandidate() throws {
        let incoming = staging.appendingPathComponent("incoming")
        try fm.copyItem(at: current, to: candidate)
        let db = candidate.appendingPathComponent(NativeBackupArchive.database)
        // SQLite's online backup sees committed WAL pages even in a configuration-only restore.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = db.path + suffix
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        }
        if !fm.fileExists(atPath: incoming.appendingPathComponent(NativeBackupArchive.database).path) {
            try RuntimeDatabase(url: current.appendingPathComponent(NativeBackupArchive.database)).backup(to: db)
        }
        for file in try fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil) {
            let destination = candidate.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: destination.path) || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: file, to: destination)
        }
    }

    func begin(_ intent: Intent) throws {
        try JSONEncoder().encode(intent).write(to: journal, options: .atomic)
    }

    func activate(_ intent: Intent) throws {
        try Data(intent.id.uuidString.utf8).write(to: candidate.appendingPathComponent(markerName), options: .atomic)
        try swapDirectories()
    }

    private func swapDirectories() throws {
        guard renamex_np(current.path, candidate.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ClientFailure("backup_directory_swap_failed")
        }
    }

    func undoSwap(_ intent: Intent) throws {
        let marker = current.appendingPathComponent(markerName)
        if fm.fileExists(atPath: marker.path), try String(contentsOf: marker, encoding: .utf8) == intent.id.uuidString {
            try swapDirectories()
        }
    }

    func finish() throws {
        try fm.removeItem(at: journal)
        // Removal of the journal is the commit. Leftovers can be cleaned on next startup.
        try? fm.removeItem(at: current.appendingPathComponent(markerName))
        try? cleanup()
    }
}

extension NativeConfigurationStore {
    func createBackup(in scratch: URL, at archive: URL, forLocalRollback: Bool = false) throws {
        try NativeBackupArchive.create(from: databaseURL.deletingLastPathComponent(), at: archive, scratch: scratch, forLocalRollback: forLocalRollback)
    }
}
