namespace V2rayM.Application.Runtime;

public interface IRuntimeShutdown
{
    bool ShouldSaveState { get; }
    Task WaitForRestoreShutdownRequestAsync(CancellationToken token);
    Task<bool> StopSchedulesAsync(CancellationToken token);
    Task<bool> DrainOperationsAsync(CancellationToken token, TimeSpan remaining);
    Task SaveStatisticsAsync();
    Task StopCoreAsync(CancellationToken token);
    Task SaveProfilesAsync();
    Task CloseStatisticsAsync();
    Task SaveConfigurationAsync(CancellationToken token);
    Task CloseDatabaseAsync();
    void Log(string message);
    void SetStage(string? stage);
}

public sealed class RuntimeShutdownService(IRuntimeShutdown runtime)
{
    public async Task<bool> ShutdownAsync(CancellationToken token, TimeSpan? budget = null)
    {
        var steps = new List<ShutdownCleanupStep>
        {
            new("restore shutdown request", async deadline =>
            { await runtime.WaitForRestoreShutdownRequestAsync(deadline.Token); return true; }),
            new("scheduled operations stop", deadline => runtime.StopSchedulesAsync(deadline.Token)),
            new("operation drain", async deadline =>
            {
                var drained = await runtime.DrainOperationsAsync(deadline.Token, deadline.Remaining);
                if (!drained) ApplicationDiagnostics.Report(runtime.Log, "Shutdown operation drain timed out; skipped all Core, state-save, and database cleanup.");
                return drained;
            }),
        };
        var saveState = runtime.ShouldSaveState;
        if (saveState)
        {
            steps.AddRange(ShutdownStatisticsCheckpoint.WrapCoreStop(runtime.SaveStatisticsAsync,
                async deadline => { await runtime.StopCoreAsync(deadline.Token); return true; }, runtime.Log));
            steps.Add(new("profile save", async _ => { await runtime.SaveProfilesAsync(); return true; }));
            steps.Add(new("statistics close", async _ => { await runtime.CloseStatisticsAsync(); return true; }));
            steps.Add(new("configuration save", async deadline => { await runtime.SaveConfigurationAsync(deadline.Token); return true; }));
            steps.Add(new("database close", async _ => { await runtime.CloseDatabaseAsync(); return true; }));
        }
        var completed = await ShutdownCleanupSequence.RunAsync(steps, budget ?? RuntimeShutdownBudgets.RuntimeCleanup,
            token, runtime.Log, runtime.SetStage);
        if (completed && saveState) ApplicationDiagnostics.Report(runtime.Log, "Runtime stopped.");
        return completed;
    }
}
