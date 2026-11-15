namespace V2rayM.Application.Updates;

public interface ICorePackageStaging<TArtifact>
{
    Task DownloadAsync(CancellationToken token);
    Task ExtractAsync(CancellationToken token);
    Task AuthenticateAsync(CancellationToken token);
    Task<string> VerifyExecutableAsync(CancellationToken token);
    TArtifact Complete(string version);
    Task DiscardTrustedAsync();
    void CleanupLocal();
    void Log(string message);
}

public sealed class CorePackageStagingService
{
    public async Task<TArtifact> StageAsync<TArtifact>(ICorePackageStaging<TArtifact> staging, CancellationToken token)
    {
        try
        {
            token.ThrowIfCancellationRequested();
            await staging.DownloadAsync(token);
            token.ThrowIfCancellationRequested();
            await staging.ExtractAsync(token);
            token.ThrowIfCancellationRequested();
            // Authentication must precede running any downloaded executable,
            // including a seemingly harmless version probe.
            await staging.AuthenticateAsync(token);
            token.ThrowIfCancellationRequested();
            var version = await staging.VerifyExecutableAsync(token);
            token.ThrowIfCancellationRequested();
            return staging.Complete(version); // Ownership transfers to the caller.
        }
        catch
        {
            try { await staging.DiscardTrustedAsync(); }
            catch (Exception cleanup) { UpdateDiagnostics.Report(staging.Log, $"Privileged staging cleanup deferred: {cleanup.Message}"); }
            try { staging.CleanupLocal(); }
            catch (Exception cleanup) { UpdateDiagnostics.Report(staging.Log, $"Package staging cleanup deferred: {cleanup.Message}"); }
            throw;
        }
    }
}
