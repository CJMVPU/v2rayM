using V2rayM.Domain.Updates;

namespace V2rayM.Application.Updates;

public enum ApplicationUpdatePhase { Checking, Completed, AwaitingValidation, Failed }
public sealed record ApplicationUpdateCheck(UpdateDecision Decision, string? Version, string? Detail);

public interface IApplicationUpdateArtifact { string Version { get; } }
public interface IApplicationUpdateRuntime
{
    bool IsStopping { get; }
    ValueTask<IUpdateOperationLease> EnterAsync();
    Task<ApplicationUpdateCheck> CheckAsync(CancellationToken token);
    Task<IApplicationUpdateArtifact> StageAsync(CancellationToken token);
    Task HandoffAsync(IApplicationUpdateArtifact artifact, CancellationToken token);
    void Cleanup(IApplicationUpdateArtifact artifact);
    void Publish(ApplicationUpdatePhase phase, string? version, string? detail);
    void Log(string message);
}

public sealed class ApplicationUpdateService(IApplicationUpdateRuntime runtime)
{
    public async Task RunAsync()
    {
        IApplicationUpdateArtifact? artifact = null;
        string? version = null;
        try
        {
            await using var lease = await runtime.EnterAsync();
            runtime.Publish(ApplicationUpdatePhase.Checking, null, null);
            var check = await runtime.CheckAsync(lease.Token);
            version = check.Version;
            lease.Token.ThrowIfCancellationRequested();
            if (check.Decision == UpdateDecision.Current)
            {
                runtime.Publish(ApplicationUpdatePhase.Completed, version, check.Detail ?? "The application is up to date.");
                return;
            }
            if (check.Decision != UpdateDecision.Available)
            {
                runtime.Publish(check.Decision == UpdateDecision.AwaitingValidation ? ApplicationUpdatePhase.AwaitingValidation : ApplicationUpdatePhase.Failed,
                    version, check.Detail ?? "The application update check did not admit a candidate.");
                return;
            }
            artifact = await runtime.StageAsync(lease.Token)
                ?? throw new InvalidOperationException("The application update did not produce a staged package.");
            lease.Token.ThrowIfCancellationRequested();
            await runtime.HandoffAsync(artifact, lease.Token);
            // The detached updater owns final health verification and completion.
        }
        catch (Exception failure)
        {
            ApplicationDiagnostics.Report(runtime.Log, $"Application update failed: {failure}");
            runtime.Publish(ApplicationUpdatePhase.Failed, artifact?.Version ?? version,
                failure is OperationCanceledException && runtime.IsStopping ? "Canceled during graceful shutdown." : failure.Message);
        }
        finally
        {
            if (artifact is not null)
            {
                try { runtime.Cleanup(artifact); }
                catch (Exception failure) { ApplicationDiagnostics.Report(runtime.Log, $"Application staging cleanup failed: {failure}"); }
            }
        }
    }
}

public interface IApplicationPackageStaging<T>
{
    Task DownloadAsync(CancellationToken token);
    Task VerifyAsync(CancellationToken token);
    void PrepareCandidate();
    T Complete();
    void Cleanup();
    void Log(string message);
}

public sealed class ApplicationPackageStagingService<T>(IApplicationPackageStaging<T> staging)
{
    public async Task<T> StageAsync(CancellationToken token)
    {
        try
        {
            token.ThrowIfCancellationRequested();
            await staging.DownloadAsync(token);
            token.ThrowIfCancellationRequested();
            await staging.VerifyAsync(token);
            token.ThrowIfCancellationRequested();
            staging.PrepareCandidate();
            token.ThrowIfCancellationRequested();
            return staging.Complete();
        }
        catch
        {
            try { staging.Cleanup(); }
            catch (Exception failure) { ApplicationDiagnostics.Report(staging.Log, $"Application package cleanup failed: {failure}"); }
            throw;
        }
    }
}
