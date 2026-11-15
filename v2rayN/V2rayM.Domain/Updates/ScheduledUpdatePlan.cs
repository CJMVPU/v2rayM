namespace V2rayM.Domain.Updates;

public sealed record ScheduledUpdateTarget(string Id, bool PreRelease, string InstalledVersion);
public sealed record ScheduledUpdatePlan(bool UseProxy, IReadOnlyList<ScheduledUpdateTarget> Targets, int ProxyPort = 0)
{
    // Advisory results are valid only for the preferences and installed builds
    // captured before network I/O. Installation always performs its own check.
    public bool Matches(ScheduledUpdatePlan current) => UseProxy == current.UseProxy && (!UseProxy || ProxyPort == current.ProxyPort) && Targets.SequenceEqual(current.Targets);
}
