namespace V2rayM.Application.Updates;

public enum ApplicationReplacementPhase { Installing, Restarting, VerifyingHealth, RollingBack }
public sealed record ApplicationReplacementResult(bool Success, bool RollbackSucceeded, string? Detail);
public interface IApplicationReplacement
{
    Task InstallAsync();
    Task<bool> StartAndVerifyCandidateAsync();
    Task RestoreFilesAsync();
    Task<bool> StartAndVerifyPreviousAsync();
    Task CleanupAsync();
    void Publish(ApplicationReplacementPhase phase);
    void Log(string message);
}

public sealed class ApplicationReplacementService(IApplicationReplacement runtime)
{
    public async Task<ApplicationReplacementResult> ApplyAsync()
    {
        string failure;
        try
        {
            Publish(ApplicationReplacementPhase.Installing);
            await runtime.InstallAsync();
            Publish(ApplicationReplacementPhase.Restarting);
            Publish(ApplicationReplacementPhase.VerifyingHealth);
            if (await runtime.StartAndVerifyCandidateAsync())
            {
                await CleanupAsync();
                return new(true, false, null);
            }
            failure = "The new application did not become healthy.";
        }
        catch (Exception installFailure) { failure = installFailure.Message; }
        Publish(ApplicationReplacementPhase.RollingBack);
        string? restoreFailure = null;
        try { await runtime.RestoreFilesAsync(); }
        catch (Exception restore) { restoreFailure = restore.Message; }
        try
        {
            Publish(ApplicationReplacementPhase.Restarting);
            Publish(ApplicationReplacementPhase.VerifyingHealth);
            if (!await runtime.StartAndVerifyPreviousAsync())
                return new(false, false, $"{failure} The previous application did not become healthy. {restoreFailure}");
            if (restoreFailure is not null)
                return new(false, false, $"{failure} The previous process is responding, but restoring all previous app files failed: {restoreFailure}");
            await CleanupAsync();
            return new(false, true, $"{failure} The previous build was restored and is healthy.");
        }
        catch (Exception restart) { return new(false, false, $"{failure} Rollback/restart failed: {restoreFailure} {restart.Message}"); }
    }
    private void Publish(ApplicationReplacementPhase phase)
    {
        try { runtime.Publish(phase); }
        catch (Exception failure) { ApplicationDiagnostics.Report(runtime.Log, $"Application update progress failed: {failure}"); }
    }
    private async Task CleanupAsync()
    {
        try { await runtime.CleanupAsync(); }
        catch (Exception failure) { ApplicationDiagnostics.Report(runtime.Log, $"Healthy application cleanup deferred: {failure}"); }
    }
}
