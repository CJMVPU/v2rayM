import Foundation
import V2rayMApplication

enum RuntimeSessionCleanup {
    static func run(stopCore: () async throws -> Void, restoreNetwork: () async throws -> Void) async throws {
        do { try await RuntimeSessionShutdown.run(stopCore: stopCore, restoreNetwork: restoreNetwork) }
        catch let failures as RuntimeSessionShutdown.Failures {
            throw ClientFailure((failures.network as? ClientFailure)?.code ?? "tun_stop_unconfirmed",
                                failures.core.localizedDescription + " · " + failures.network.localizedDescription)
        }
    }
}
