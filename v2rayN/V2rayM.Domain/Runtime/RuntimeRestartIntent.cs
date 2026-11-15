namespace V2rayM.Domain.Runtime;

public sealed record RuntimeRestartIntent(bool WasRunning, string? PreferredProfileId)
{
    public string Reason { get; init; } = "Restore";

    // A missing preferred node may legitimately recover to another usable node.
    public bool IsSatisfied(CoreRuntimeState? state, bool hasCore, string? activeProfileId) => WasRunning
        ? state == CoreRuntimeState.Running && hasCore && !string.IsNullOrWhiteSpace(activeProfileId)
        : state == CoreRuntimeState.Stopped && !hasCore;
}

public static class RuntimeStartupPolicy
{
    public static bool ShouldAutoStart(RuntimeRestartIntent? intent, bool configured, bool setupRequired = false) =>
        !setupRequired && intent is null && configured;
    public static bool ShouldRecoverCore(RuntimeRestartIntent? intent, bool setupRequired) =>
        !setupRequired && intent?.WasRunning == true;
}
