namespace V2rayM.Application.Settings;

/// The caller holds exclusive maintenance and the settings lifecycle lease until
/// this session completes. Recovery deliberately outlives request cancellation.
public interface IRegionalPresetSession
{
    bool IsCurrent { get; }
    Task WriteConfigurationAsync(CancellationToken cancellationToken);
    Task<bool> RestoreConfigurationAsync();
    Task<SettingsRollbackResult> RestoreRuntimeAsync(string reason, bool filesRestored = true);
    Task UpdateFilesAsync(Func<Func<Task>, CancellationToken, Task> beforeCommit, CancellationToken cancellationToken);
    Task<bool> ApplyRuntimeAsync(Func<Task> rollbackFiles);
    bool FilesWereRestored(Exception exception);
    void Log(string message);
}

public enum RegionalPresetStatus { Applied, Conflict, ConfigurationFailed, RuntimeFailed, FilesFailed }
public sealed record RegionalPresetResult(RegionalPresetStatus Status,
    SettingsRollbackResult? Rollback = null, bool FilesRestored = true);

public sealed class RegionalPresetService
{
    public async Task<RegionalPresetResult> ApplyAsync(IRegionalPresetSession session, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // No writes or compensating restore on conflict: the newer local state owns
        // the data, including edits made while remote templates were downloading.
        if (!session.IsCurrent) return new(RegionalPresetStatus.Conflict);
        SettingsRollbackResult? rollback = null;
        var runtimeFailed = false;
        try
        {
            await RegionalPresetApplyWorkflow.RunAsync(async token =>
            {
                var config = await RegionalPresetTransaction.RunAsync(
                    () => session.WriteConfigurationAsync(token), session.RestoreConfigurationAsync);
                if (config.Success) return;
                ApplicationDiagnostics.Report(session.Log, $"Configuration apply failed; restored={config.RollbackSucceeded}: {config.Error}");
                if (!config.RollbackSucceeded)
                {
                    rollback = await session.RestoreRuntimeAsync(token.IsCancellationRequested
                        ? "regional_preset_config_cancelled" : "regional_preset_config_apply_failed");
                }
                token.ThrowIfCancellationRequested();
                throw new ConfigurationApplyException();
            }, session.UpdateFilesAsync, async (restoreFiles, token) =>
            {
                token.ThrowIfCancellationRequested();
                // From here the runtime must complete apply/recovery even if the
                // client disconnects. Its recovery restores files before relaunch.
                runtimeFailed = !await session.ApplyRuntimeAsync(restoreFiles);
                if (runtimeFailed) throw new RegionalPresetCoreApplyFailedException();
            }, async exception =>
            {
                if (!runtimeFailed)
                    rollback = await session.RestoreRuntimeAsync("regional_preset_geofiles_failed", session.FilesWereRestored(exception));
            }, cancellationToken);
            return new(RegionalPresetStatus.Applied);
        }
        catch (ConfigurationApplyException) { return new(RegionalPresetStatus.ConfigurationFailed, rollback); }
        catch (RegionalPresetCoreApplyFailedException) { return new(RegionalPresetStatus.RuntimeFailed); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            ApplicationDiagnostics.Report(session.Log, $"Regional preset apply/recovery failed: {exception}");
            var filesRestored = session.FilesWereRestored(exception);
            if (runtimeFailed) return new(RegionalPresetStatus.RuntimeFailed, FilesRestored: filesRestored);
            rollback ??= await session.RestoreRuntimeAsync("regional_preset_geofiles_failed", filesRestored);
            return new(RegionalPresetStatus.FilesFailed, rollback, filesRestored);
        }
    }

    private sealed class ConfigurationApplyException : Exception;
}
