import Foundation
import V2rayMDomain

public typealias NetworkRecovery = V2rayMDomain.NetworkRecovery

extension NetworkRecovery {
    public static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? ProxyModeFailure {
            return !failure.rollbackFailed && isTransient(failure.underlying)
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .cancelled].contains(error.code)
    }
}
