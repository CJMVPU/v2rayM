import Foundation
import TunShared

/// Poll results describe one helper session. A later healthy observation supersedes
/// a brief interruption, without altering failures owned by start, stop or cleanup.
struct TunSessionObservation {
    private var sequence: UInt64 = 0
    private var latest: (session: UUID, poll: UInt64, result: HelperResponse)?

    mutating func begin() -> UInt64 {
        sequence += 1
        return sequence
    }

    mutating func record(_ result: HelperResponse, for session: UUID, poll: UInt64) -> Bool {
        if let latest, latest.poll >= poll { return false }
        var status = result
        status.logs = []
        latest = (session, poll, status)
        return true
    }

    func response(for session: UUID?) -> HelperResponse? {
        guard let latest, latest.session == session else { return nil }
        return latest.result
    }

    func failure(for session: UUID?) -> String? {
        guard let result = response(for: session) else { return nil }
        if !result.success { return result.code }
        return result.state == "running" ? nil : "helper_tunnel_not_running"
    }
}
