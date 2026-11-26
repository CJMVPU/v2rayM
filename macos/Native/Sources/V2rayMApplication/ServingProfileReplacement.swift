/// Applies a validated change to the serving node while its caller holds the runtime mutation lease.
package enum ServingProfileReplacement {
    package static func apply(next: String?, disconnect: @escaping () async throws -> Void,
                              launch: (String) async throws -> Void, commit: () async throws -> Void,
                              restorePrevious: @escaping () async throws -> Void) async throws -> Bool {
        try await disconnect()
        do {
            try Task.checkCancellation()
            if let next { try await launch(next) }
            try Task.checkCancellation()
            try await commit()
        } catch {
            // The old session must be restored even when cancellation interrupted the edit.
            try await Task {
                try await disconnect()
                try await restorePrevious()
            }.value
            throw error
        }
        return next != nil
    }
}
