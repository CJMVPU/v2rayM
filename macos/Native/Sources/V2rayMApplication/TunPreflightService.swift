import V2rayMDomain

public enum TunPreflightService {
    public static func check(_ state: TunModeState, requestingTun: Bool,
                             checkOtherTunnel: @Sendable () async throws -> Void) async throws {
        switch state.connectionAdmission(requestingTun: requestingTun) {
        case .allowed: return
        case .helperRequired: throw ModeSwitchRejection.helperUnavailable
        case .checkOtherTunnel: try await checkOtherTunnel()
        }
    }
}
