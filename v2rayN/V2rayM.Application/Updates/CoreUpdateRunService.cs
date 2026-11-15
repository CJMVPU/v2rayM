using V2rayM.Domain.Updates;

namespace V2rayM.Application.Updates;

public interface IUpdateOperationLease : IAsyncDisposable { CancellationToken Token { get; } }
public interface ICoreUpdateArtifact { string Version { get; } }
public sealed record CoreUpdateCheck(UpdateDecision Decision, string? Version, string? Detail);
public enum CoreUpdateRunPhase { Checking, Completed, AwaitingValidation, Failed }
public sealed record CoreUpdateRunProgress(CoreUpdateRunPhase Phase, bool Success, bool CoreWasRunning,
    string? Version = null, string? Detail = null);

public interface ICoreUpdateRun
{
    bool WasRunning { get; }
    bool IsStopping { get; }
    ValueTask<IUpdateOperationLease> EnterStagingAsync();
    ValueTask<IUpdateOperationLease> EnterApplyAsync();
    Task<CoreUpdateCheck> CheckAsync(CancellationToken token);
    Task<ICoreUpdateArtifact> StageAsync(CancellationToken token);
    Task<CoreUpdateApplyResult> ApplyAsync(ICoreUpdateArtifact artifact, CancellationToken token);
    Task DiscardTrustedAsync(ICoreUpdateArtifact artifact);
    void CleanupLocal(ICoreUpdateArtifact artifact);
    void Publish(CoreUpdateRunProgress progress);
    void Log(string message);
}

public sealed class CoreUpdateRunService
{
    public async Task RunAsync(ICoreUpdateRun run)
    {
        ICoreUpdateArtifact? artifact = null;
        try
        {
            CoreUpdateCheck check;
            await using (var staging = await run.EnterStagingAsync())
            {
                run.Publish(new(CoreUpdateRunPhase.Checking, false, run.WasRunning));
                check = await run.CheckAsync(staging.Token);
                switch (check.Decision)
                {
                    case UpdateDecision.Current:
                    case UpdateDecision.AwaitingValidation: break;
                    case UpdateDecision.Available:
                        staging.Token.ThrowIfCancellationRequested();
                        artifact = await run.StageAsync(staging.Token)
                            ?? throw new InvalidOperationException("Staging did not produce an update artifact.");
                        break;
                    default: throw new InvalidOperationException(check.Detail ?? "Could not check Core updates.");
                }
            }
            CoreUpdateApplyResult result;
            if (artifact is null)
            {
                var pending = check.Decision == UpdateDecision.AwaitingValidation;
                result = new(!pending, false, run.WasRunning,
                    check.Detail ?? (pending ? "Awaiting compatibility validation." : "Already up to date."),
                    check.Version, AwaitingValidation: pending);
            }
            else
            {
                // Staging's shared lease must be released before requesting
                // exclusive maintenance. Never upgrade an owned shared lease.
                await using var apply = await run.EnterApplyAsync();
                result = await run.ApplyAsync(artifact, apply.Token);
            }
            run.Publish(new(result.AwaitingValidation ? CoreUpdateRunPhase.AwaitingValidation : CoreUpdateRunPhase.Completed,
                result.Success, result.CoreWasRunning, result.Version ?? artifact?.Version, result.Detail));
            if (!result.Success && !result.AwaitingValidation) ApplicationDiagnostics.Report(run.Log, $"Update failed: {result.Detail}");
        }
        catch (OperationCanceledException) when (run.IsStopping)
        {
            run.Publish(new(CoreUpdateRunPhase.Failed, false, run.WasRunning, artifact?.Version, "Canceled during graceful shutdown."));
        }
        catch (Exception exception)
        {
            ApplicationDiagnostics.Report(run.Log, $"Update failed: {exception.Message}");
            run.Publish(new(CoreUpdateRunPhase.Failed, false, run.WasRunning, artifact?.Version, exception.Message));
        }
        finally
        {
            if (artifact is not null)
            {
                try { await run.DiscardTrustedAsync(artifact); }
                catch (Exception cleanup) { ApplicationDiagnostics.Report(run.Log, $"Privileged staging cleanup deferred: {cleanup.Message}"); }
                try { run.CleanupLocal(artifact); }
                catch (Exception cleanup) { ApplicationDiagnostics.Report(run.Log, $"Package staging cleanup deferred: {cleanup.Message}"); }
            }
        }
    }
}
