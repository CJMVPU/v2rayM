import Foundation

enum NativeMaintenance: Equatable {
    case subscriptions, saveState, cleanFiles, geo

    static func due(minute: Int, geoHours: Int) -> [Self] {
        guard minute > 0 else { return [] }
        var actions: [Self] = [.subscriptions]
        if minute.isMultiple(of: 20) { actions.append(.saveState) }
        if minute.isMultiple(of: 60) {
            actions.append(.cleanFiles)
            if geoHours > 0, (minute / 60).isMultiple(of: geoHours) { actions.append(.geo) }
        }
        return actions
    }

    /// Old releases accumulate top-level test files, logs and temporary downloads.
    /// Active core configurations live below their private per-session directories.
    static func clean(in root: URL, now: Date) throws {
        let fm = FileManager.default
        for (name, hours, contains) in [("binConfigs", 1, "Test"), ("guiLogs", 168, ""), ("guiTemps", 168, "")] {
            let dir = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: dir.path), try dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            let deadline = now.addingTimeInterval(-Double(hours * 3600))
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey]) {
                let filename = file.lastPathComponent
                if !contains.isEmpty && !filename.contains(contains) { continue }
                if ["native-xray.log","native-presocks.log"].contains(filename) { continue }
                let info = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey])
                if info.isRegularFile == true, info.isSymbolicLink != true, let date = info.contentModificationDate, date < deadline {
                    try fm.removeItem(at: file)
                }
            }
        }
    }
}

extension NativeConfigurationStore {
    /// Native edits commit immediately. Checkpoint already committed WAL pages on the legacy save cadence.
    func checkpoint() throws {
        _ = try RuntimeDatabase(url: databaseURL, writable: true).query("PRAGMA wal_checkpoint(PASSIVE)")
    }
}
