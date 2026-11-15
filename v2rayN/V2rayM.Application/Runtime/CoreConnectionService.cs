using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Runtime;

public sealed record CoreConnectionProfile(string Id);
public interface ICoreLaunchPlan
{
    string ProfileId { get; }
    int ProxyPort { get; }
}

public interface ICoreConnectionRuntime
{
    CoreConnectionState Current { get; }
    Task<CoreConnectionProfile?> ResolveProfileAsync(string? id);
    Task SelectProfileAsync(string id);
    void ResetConfigurationCache();
    Task<ICoreLaunchPlan?> PrepareAsync(CoreConnectionProfile profile);
    Task<bool> IsPortOccupiedAsync(ICoreLaunchPlan plan, CancellationToken token);
    void SetTransition(CoreRuntimeState state);
    void SetStopped();
    void SetStarting(ICoreLaunchPlan plan);
    void SetRunning();
    void SetFaulted(string detail);
    Task StopMonitorAsync();
    Task StopAndConfirmAsync(CancellationToken token);
    Task LaunchAsync(ICoreLaunchPlan plan);
    Task<bool> WaitForListenerAsync(ICoreLaunchPlan plan, CancellationToken token);
    Task StartMonitorAsync();
    Task PublishStatusAsync();
    void Log(string message);
}

public enum CoreConnectionStatus
{
    Started, Stopped, Restarted, AlreadyRunning, SelectionSaved,
    ProfileMissing, NoSelection, SelectionRequiresStop, NotRunning,
    PreflightRejected, PortOccupied, StopFailed, StartFailed, RestartFailed,
}
public sealed record CoreConnectionResult(CoreConnectionStatus Status, string? ProfileId = null,
    IReadOnlyList<int>? ProcessIds = null, string? Detail = null, string? Stage = null, int? Port = null);

/// Every entry point is called under the same lifecycle lease. Upstream models,
/// process ownership, listener probes and helper trust remain adapter concerns.
public sealed class CoreConnectionService(ICoreConnectionRuntime runtime)
{
    public async Task<CoreConnectionResult> SelectOnlyAsync(string id)
    {
        var profile = await runtime.ResolveProfileAsync(id);
        if (profile is null) return new(CoreConnectionStatus.ProfileMissing, id);
        if (!runtime.Current.CanSelectWithoutConnecting) return new(CoreConnectionStatus.SelectionRequiresStop);
        await runtime.SelectProfileAsync(profile.Id);
        return new(CoreConnectionStatus.SelectionSaved, profile.Id);
    }

    public async Task<CoreConnectionResult> StartAsync(string? id, CancellationToken token, bool selectProfile = false)
    {
        var profile = await runtime.ResolveProfileAsync(id);
        if (profile is null) return new(id is null ? CoreConnectionStatus.NoSelection : CoreConnectionStatus.ProfileMissing, id);
        if (!selectProfile && runtime.Current.IsAlreadyRunning(profile.Id))
            return new(CoreConnectionStatus.AlreadyRunning, profile.Id);
        var plan = await runtime.PrepareAsync(profile);
        if (plan is null) return new(CoreConnectionStatus.PreflightRejected, profile.Id);
        if (selectProfile) await runtime.SelectProfileAsync(profile.Id);
        return await LaunchAsync(plan, token);
    }

    public async Task<CoreConnectionResult> StopAsync(CancellationToken token)
    {
        if (!runtime.Current.RequiresStop) return new(CoreConnectionStatus.Stopped);
        runtime.SetTransition(CoreRuntimeState.Stopping);
        try
        {
            await runtime.StopMonitorAsync();
            await runtime.StopAndConfirmAsync(token);
            runtime.SetStopped();
            runtime.Log("Core stopped.");
            await runtime.PublishStatusAsync();
            return new(CoreConnectionStatus.Stopped);
        }
        catch (Exception exception)
        {
            runtime.SetFaulted(exception.Message);
            runtime.Log($"Core stop failed: {exception}");
            await runtime.PublishStatusAsync();
            return Failure(CoreConnectionStatus.StopFailed, exception.Message);
        }
    }

    public async Task<CoreConnectionResult> RestartAsync(CancellationToken token)
    {
        var previous = runtime.Current;
        if (!previous.CanRestart) return new(CoreConnectionStatus.NotRunning, ProcessIds: previous.ProcessIds, Stage: previous.State.ToString());
        var profile = await runtime.ResolveProfileAsync(previous.ProfileId);
        if (profile is null) return new(CoreConnectionStatus.ProfileMissing, previous.ProfileId);
        runtime.ResetConfigurationCache();
        var stage = "preflight";
        try
        {
            var plan = await runtime.PrepareAsync(profile);
            if (plan is null) return new(CoreConnectionStatus.PreflightRejected, profile.Id);
            stage = "stop";
            runtime.SetTransition(CoreRuntimeState.Restarting);
            await runtime.StopMonitorAsync();
            await runtime.StopAndConfirmAsync(token);
            runtime.SetStopped();
            stage = "start";
            var result = await LaunchAsync(plan, token);
            return result.Status == CoreConnectionStatus.Started ? result with { Status = CoreConnectionStatus.Restarted } : result;
        }
        catch (Exception exception)
        {
            // A preflight failure has not touched the serving process or its state.
            if (stage != "preflight") runtime.SetFaulted(exception.Message);
            runtime.Log($"Core restart failed during {stage}: {exception}");
            return Failure(stage == "stop" ? CoreConnectionStatus.StopFailed : CoreConnectionStatus.RestartFailed,
                exception.Message) with { Stage = stage };
        }
    }

    private async Task<CoreConnectionResult> LaunchAsync(ICoreLaunchPlan plan, CancellationToken token)
    {
        if (!runtime.Current.RequiresStop && await runtime.IsPortOccupiedAsync(plan, token))
            return new(CoreConnectionStatus.PortOccupied, Port: plan.ProxyPort);
        if (runtime.Current.RequiresStop)
        {
            runtime.SetTransition(CoreRuntimeState.Stopping);
            try
            {
                await runtime.StopMonitorAsync();
                await runtime.StopAndConfirmAsync(token);
                runtime.SetStopped();
            }
            catch (Exception exception)
            {
                runtime.SetFaulted(exception.Message);
                runtime.Log($"Core stop before launch failed: {exception}");
                return Failure(CoreConnectionStatus.StopFailed, exception.Message);
            }
        }
        runtime.SetStarting(plan);
        try
        {
            await runtime.LaunchAsync(plan);
            var listening = await runtime.WaitForListenerAsync(plan, token);
            if (!listening || !runtime.Current.HasActiveChildren)
            {
                var detail = !listening ? "The Core process did not open its configured proxy listener."
                    : "The Web runtime could not identify a live Core child process.";
                detail = await CleanupFailedStartAsync(detail);
                runtime.SetFaulted(detail);
                runtime.Log(detail);
                await runtime.PublishStatusAsync();
                return Failure(CoreConnectionStatus.StartFailed, detail, plan.ProfileId);
            }
            runtime.SetRunning();
            await runtime.StartMonitorAsync();
            runtime.Log("Core started.");
            await runtime.PublishStatusAsync();
            return new(CoreConnectionStatus.Started, plan.ProfileId, runtime.Current.ProcessIds);
        }
        catch (Exception exception)
        {
            runtime.Log($"Core start failed: {exception}");
            var detail = exception.Message;
            if (runtime.Current.State == CoreRuntimeState.Starting || runtime.Current.HasActiveChildren)
                detail = await CleanupFailedStartAsync(detail);
            runtime.SetFaulted(detail);
            await runtime.PublishStatusAsync();
            return Failure(CoreConnectionStatus.StartFailed, detail, plan.ProfileId);
        }
    }

    private async Task<string> CleanupFailedStartAsync(string detail)
    {
        try { await runtime.StopAndConfirmAsync(CancellationToken.None); }
        catch (Exception exception)
        {
            runtime.Log($"Core start cleanup failed: {exception}");
            detail += $" Cleanup also failed: {exception.Message}";
        }
        return detail;
    }

    private CoreConnectionResult Failure(CoreConnectionStatus status, string detail, string? profileId = null) =>
        new(status, profileId, runtime.Current.ProcessIds, detail);
}
