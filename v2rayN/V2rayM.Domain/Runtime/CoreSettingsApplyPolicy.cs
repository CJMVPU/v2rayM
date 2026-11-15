namespace V2rayM.Domain.Runtime;

public enum CoreSettingsApplyAction
{
    SaveOnly,
    Restart,
    Busy,
    Inconsistent,
}

public static class CoreSettingsApplyPolicy
{
    public static CoreSettingsApplyAction Decide(CoreRuntimeState state, bool hasActiveChild, bool changed) => state switch
    {
        CoreRuntimeState.Stopped when !hasActiveChild => CoreSettingsApplyAction.SaveOnly,
        CoreRuntimeState.Stopped => CoreSettingsApplyAction.Inconsistent,
        CoreRuntimeState.Running when hasActiveChild && changed => CoreSettingsApplyAction.Restart,
        CoreRuntimeState.Running when hasActiveChild => CoreSettingsApplyAction.SaveOnly,
        CoreRuntimeState.Running => CoreSettingsApplyAction.Inconsistent,
        CoreRuntimeState.Faulted when hasActiveChild => CoreSettingsApplyAction.Restart,
        CoreRuntimeState.Faulted => CoreSettingsApplyAction.SaveOnly,
        CoreRuntimeState.Starting or CoreRuntimeState.Stopping or CoreRuntimeState.Restarting => CoreSettingsApplyAction.Busy,
        _ => CoreSettingsApplyAction.Inconsistent,
    };
}
