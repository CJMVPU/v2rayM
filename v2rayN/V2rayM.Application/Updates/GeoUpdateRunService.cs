namespace V2rayM.Application.Updates;

public enum GeoUpdatePhase { Downloading, Restarting, RollingBack, Completed, Failed }
public interface IGeoUpdateRun
{
    bool IsStopping { get; }
    bool WasRunning { get; }
    ValueTask<IUpdateOperationLease> EnterAsync();
    Task ApplyFilesAsync(Func<Func<Task>, CancellationToken, Task>? beforeCommit, CancellationToken token);
    Task<bool> RestartAsync(CancellationToken token);
    void Publish(GeoUpdatePhase phase, string? detail = null);
    void Log(string message);
}

public sealed class GeoUpdateRunService
{
    private static void Publish(IGeoUpdateRun run, GeoUpdatePhase phase, string? detail = null)
    {
        try { run.Publish(phase, detail); }
        catch (Exception failure) { ApplicationDiagnostics.Report(run.Log, $"GeoFiles progress publication failed: {failure.Message}"); }
    }

    public async Task RunAsync(IGeoUpdateRun run)
    {
        try
        {
            Publish(run, GeoUpdatePhase.Downloading);
            await using var lease = await run.EnterAsync();
            lease.Token.ThrowIfCancellationRequested();
            var wasRunning = run.WasRunning;
            await run.ApplyFilesAsync(wasRunning ? async (rollback, token) =>
            {
                Publish(run, GeoUpdatePhase.Restarting);
                try
                {
                    if (!await run.RestartAsync(token))
                        throw new InvalidOperationException("The serving core did not restart after the rule update.");
                }
                catch
                {
                    // Progress observers must not prevent recovery of the files
                    // and the previous process after a failed serving-core reload.
                    Publish(run, GeoUpdatePhase.RollingBack);
                    await rollback();
                    if (!await run.RestartAsync(CancellationToken.None))
                        ApplicationDiagnostics.Report(run.Log, "Previous rules restored, but Core recovery was not confirmed.");
                    throw;
                }
            } : null, lease.Token);
            Publish(run, GeoUpdatePhase.Completed);
        }
        catch (OperationCanceledException) when (run.IsStopping)
        {
            Publish(run, GeoUpdatePhase.Failed, "Canceled during graceful shutdown.");
        }
        catch (Exception failure)
        {
            ApplicationDiagnostics.Report(run.Log, $"GeoFiles update failed: {failure.Message}");
            Publish(run, GeoUpdatePhase.Failed, failure.Message);
        }
    }
}
