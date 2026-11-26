import Foundation

enum RuntimeSessionCleanup {
    static func run(stopCore: () async throws -> Void, restoreNetwork: () async throws -> Void) async throws {
        var coreError: Error?
        do { try await stopCore() } catch { coreError = error }
        do { try await restoreNetwork() }
        catch {
            if let coreError {
                throw ClientFailure((error as? ClientFailure)?.code ?? "tun_stop_unconfirmed",
                                    coreError.localizedDescription + " · " + error.localizedDescription)
            }
            throw error
        }
        if let coreError { throw coreError }
    }
}
