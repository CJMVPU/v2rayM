using V2rayM.Domain.Updates;

namespace V2rayM.Application.Updates;

public sealed record ScheduledUpdateResult(string Target, bool Available, string? Detail);
public interface IScheduledUpdateCheck
{
    Task<ScheduledUpdatePlan> CaptureAsync(CancellationToken token);
    Task<ScheduledUpdateResult> CheckRemoteAsync(ScheduledUpdateTarget target, bool useProxy, int proxyPort, CancellationToken token);
    Task<bool> TryPublishAsync(ScheduledUpdatePlan captured, IReadOnlyList<ScheduledUpdateResult> results, CancellationToken token);
    void Log(string message);
}

public sealed class ScheduledUpdateCheckService(IScheduledUpdateCheck runtime)
{
    // The scheduled task owner tracks/drains this entire operation. Only capture
    // and publication own runtime leases; network I/O touches detached values.
    public async Task RunAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var plan = await runtime.CaptureAsync(token);
        var results = new List<ScheduledUpdateResult>(plan.Targets.Count);
        foreach (var target in plan.Targets)
        {
            token.ThrowIfCancellationRequested();
            try { results.Add(await runtime.CheckRemoteAsync(target, plan.UseProxy, plan.ProxyPort, token)); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception failure)
            {
                UpdateDiagnostics.Report(runtime.Log, $"Scheduled update check failed for {target.Id}: {failure}");
                results.Add(new(target.Id, false, failure.Message));
            }
            token.ThrowIfCancellationRequested();
        }
        if (results.Count == 0) return;
        token.ThrowIfCancellationRequested();
        await runtime.TryPublishAsync(plan, results, token);
    }
}
