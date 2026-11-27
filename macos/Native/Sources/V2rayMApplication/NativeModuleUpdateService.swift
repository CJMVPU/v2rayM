import Foundation

public protocol NativeModuleUpdateRuntime: Sendable {
    func submitGeoUpdate(useProxy: Bool?) async throws
}

@MainActor public struct NativeModuleUpdateService {
    public init() {}
    public func submit(to runtime: any NativeModuleUpdateRuntime) async throws {
        try Task.checkCancellation()
        try await runtime.submitGeoUpdate(useProxy: nil)
        // Once accepted, observation failure/cancellation must not pretend that
        // the background update was undone. Its owner observes progress separately.
    }
}
