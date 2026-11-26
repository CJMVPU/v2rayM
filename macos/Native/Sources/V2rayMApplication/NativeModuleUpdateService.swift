import Foundation
import V2rayMDomain

@MainActor public protocol NativeModuleUpdateRuntime: AnyObject {
    func submit(_ scope: ModuleUpdateScope) async throws
}

@MainActor public struct NativeModuleUpdateService {
    public init() {}
    public func submit(_ scope: ModuleUpdateScope, runtime: any NativeModuleUpdateRuntime) async throws {
        try Task.checkCancellation()
        try await runtime.submit(scope)
        // Once accepted, observation failure/cancellation must not pretend that
        // the background update was undone. Its owner observes progress separately.
    }
}
