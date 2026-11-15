public enum CommandFailureDisposition { case report, retryDisconnect, retryRecovery }

public struct CommandFailurePolicy {
    public static func resolve(finishingDisconnect: Bool, desiredMode: ProxyMode, transient: Bool,
                               modeSwitchFailure: Bool, recoveryActive: Bool) -> CommandFailureDisposition {
        if finishingDisconnect && desiredMode == .off && transient && modeSwitchFailure { return .retryDisconnect }
        if recoveryActive && transient { return .retryRecovery }
        return .report
    }
}
