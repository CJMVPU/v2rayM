/// Network restoration must be attempted even if the embedded core fails to stop.
package enum RuntimeSessionShutdown {
    package struct Failures: Error {
        package let core: Error
        package let network: Error
    }

    package static func run(stopCore: () async throws -> Void, restoreNetwork: () async throws -> Void) async throws {
        var coreError: Error?
        do { try await stopCore() } catch { coreError = error }
        do { try await restoreNetwork() }
        catch {
            if let coreError { throw Failures(core: coreError, network: error) }
            throw error
        }
        if let coreError { throw coreError }
    }
}
