import Darwin
import Foundation

/// Only the original caller and start token can obtain proof. Only completed
/// cleanups survive a daemon exit; losing a pending session never confirms it.
public final class SessionRecoveryStore {
    private struct Receipt: Codable {
        let token: UUID
        let owner: uid_t
        var confirmed: Bool?
    }

    private let lock = NSLock()
    private var receipts: [Receipt] = []
    private let capacity: Int
    private let archive: URL?

    public init(capacity: Int = 256) {
        self.capacity = capacity
        archive = nil
    }

    /// The daemon supplies a fixed directory under the root-owned /private/var/db.
    public init(directory: URL, capacity: Int = 256) throws {
        self.capacity = capacity
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw HelperFailure("receipt_store_unavailable") }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
            throw HelperFailure("receipt_store_untrusted")
        }
        let url = directory.appendingPathComponent("completed.json")
        archive = url
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw HelperFailure("receipt_store_unavailable") }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              info.st_size <= 128 * 1024 else { throw HelperFailure("receipt_store_untrusted") }
        let saved = try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: url))
        guard saved.count <= capacity, saved.allSatisfy({ $0.confirmed == true }),
              Set(saved.map(\.token)).count == saved.count else { throw HelperFailure("receipt_store_invalid") }
        receipts = saved
    }

    private func persist(_ records: [Receipt]) throws {
        guard let archive else { return }
        let completed = records.filter { $0.confirmed == true }
        try JSONEncoder().encode(completed).write(to: archive, options: .atomic)
    }

    public func begin(_ token: String?, owner: uid_t = geteuid()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let token = token.flatMap(UUID.init(uuidString:)), !receipts.contains(where: { $0.token == token }) else {
            return false
        }
        if receipts.count >= capacity {
            guard let index = receipts.firstIndex(where: { $0.confirmed != nil }) else { return false }
            var remaining = receipts
            let evicted = remaining.remove(at: index)
            // Do not admit a new lease until the previous proof is durably evicted.
            if evicted.confirmed == true { try persist(remaining) }
            receipts = remaining
        }
        receipts.append(Receipt(token: token, owner: owner, confirmed: nil))
        return true
    }

    public func finish(_ token: String, confirmed: Bool, owner: uid_t = geteuid()) throws {
        lock.lock(); defer { lock.unlock() }
        guard let token = UUID(uuidString: token),
              let index = receipts.firstIndex(where: { $0.token == token && $0.owner == owner && $0.confirmed == nil })
        else { return }
        var updated = receipts
        var completed = updated.remove(at: index)
        completed.confirmed = confirmed
        updated.append(completed)
        if confirmed { try persist(updated) }
        receipts = updated
    }

    public func status(_ token: String?, owner: uid_t = geteuid()) -> HelperResponse {
        lock.lock(); defer { lock.unlock() }
        guard let token = token.flatMap(UUID.init(uuidString:)),
              let record = receipts.first(where: { $0.token == token && $0.owner == owner }) else {
            return HelperResponse(success: false, code: "session_cleanup_unknown", state: "unavailable")
        }
        switch record.confirmed {
        case true: return HelperResponse(code: "session_cleanup_confirmed", state: "stopped")
        case false: return HelperResponse(success: false, code: "session_cleanup_unconfirmed", state: "faulted")
        default: return HelperResponse(success: false, code: "session_cleanup_pending", state: "stopping")
        }
    }
}
