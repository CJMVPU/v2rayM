using V2rayM.Domain.Runtime;

namespace V2rayM.Domain.Updates;

public enum TrustedRollbackDisposition { Restored, AlreadyCommitted }

public sealed record UpdateRecoveryState(bool CoreStopped, bool CandidateInstalled, bool TrustedActivationRequested, bool BackupExists)
{
    public bool RequiresRecovery => CoreStopped || CandidateInstalled || TrustedActivationRequested || BackupExists;
}

public static class CoreUpdatePolicy
{
    public static bool IsTargetRunning(CoreRuntimeState state, bool targetMatches, bool hasActiveChild) =>
        (state is CoreRuntimeState.Running or CoreRuntimeState.Faulted) && targetMatches && hasActiveChild;
}
