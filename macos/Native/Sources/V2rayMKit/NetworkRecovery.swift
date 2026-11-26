import Foundation
import V2rayMDomain

public typealias NetworkRecovery = V2rayMDomain.NetworkRecovery

extension NetworkRecovery {
    public static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? ProxyModeFailure {
            guard !failure.rollbackFailed else { return false }
            // A subscription or configuration commit can temporarily own the host.
            if let rejection = failure.underlying as? ClientFailure, rejection.code == "operation_in_progress" { return true }
            return isTransient(failure.underlying)
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .cancelled].contains(error.code)
    }
}
