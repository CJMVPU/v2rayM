namespace V2rayM.Domain.Runtime;

public sealed record CoreConnectionState(CoreRuntimeState State, string? ProfileId, IReadOnlyList<int> ProcessIds)
{
    public bool HasActiveChildren => ProcessIds.Count > 0;
    public bool RequiresStop => State != CoreRuntimeState.Stopped || HasActiveChildren;
    public bool CanRestart => (State is CoreRuntimeState.Running or CoreRuntimeState.Faulted) && !string.IsNullOrEmpty(ProfileId);
    public bool CanSelectWithoutConnecting => State == CoreRuntimeState.Stopped && !HasActiveChildren;
    public bool IsAlreadyRunning(string profileId) => State == CoreRuntimeState.Running
        && ProfileId == profileId && HasActiveChildren;
}
