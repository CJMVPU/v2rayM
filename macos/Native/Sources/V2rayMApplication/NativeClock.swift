import Foundation

/// Time is supplied by the host; application orchestration can run without UI or I/O.
public protocol NativeClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}
