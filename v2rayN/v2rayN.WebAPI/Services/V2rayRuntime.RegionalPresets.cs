using ServiceLib.Enums;
using ServiceLib.Services;
using V2rayM.Application.Settings;
using v2rayN.WebAPI.Adapters.Settings;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    public async Task<OperationView> ApplyRegionalPresetAsync(EPresetType preset, CancellationToken cancellationToken = default)
    {
        if (preset is not (EPresetType.Default or EPresetType.Russia or EPresetType.Iran))
            return OperationView.Fail("regional_preset_invalid", ApiMessageKeys.RegionalPresetInvalid);

        using var shutdown = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _operations.ShutdownToken);
        var token = shutdown.Token;
        await _regionalPresetGate.WaitAsync(token);
        try
        {
            RuntimeConfigSnapshot baseline;
            // Release the shared operation before downloads and exclusive apply.
            // Never promote a shared lease while still owning it.
            await using (var read = await _operations.EnterOperationAsync(token))
            {
                baseline = await _mutations.RunAsync(() => _configStore.CaptureAsync(), read.Token);
            }
            var expectedState = ServiceLibRegionalPresetStore.Fingerprint(baseline);
            var proxy = preset == EPresetType.Default ? null : await GetRegionalPresetProxyAsync(token);
            var stager = new RegionalPresetStager((url, webProxy, downloadToken) =>
                new DownloadService().TryDownloadString(url, webProxy, string.Empty, downloadToken));
            return await RegionalPresetWorkflow.RunAsync(
                async stageToken => (await stager.StageAsync(preset, baseline.Dns, baseline.Routing,
                    proxy, stageToken, baseline.Config.RoutingBasicItem.RoutingIndexId)) with { ExpectedState = expectedState },
                ApplyStagedRegionalPresetAsync, token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (RegionalPresetStagingException exception)
        {
            AddLog("settings", $"Regional preset staging failed ({preset}); no settings were changed: {exception.InnerException}");
            return OperationView.Fail("regional_preset_failed", ApiMessageKeys.RegionalPresetFailed);
        }
        catch (Exception exception)
        {
            AddLog("settings", $"Regional preset workflow failed ({preset}): {exception}");
            return OperationView.Fail("regional_preset_failed", ApiMessageKeys.RegionalPresetFailed);
        }
        finally { _regionalPresetGate.Release(); }
    }

    private async Task<OperationView> ApplyStagedRegionalPresetAsync(RegionalPresetStage stage, CancellationToken token)
    {
        await using var maintenance = await _operations.EnterExclusiveAsync(token, allowReadOnlyObservations: true);
        await using var context = await BeginCoreSettingsApplyAsync(maintenance.Token);
        if (context.Failure is { } failure) return failure;
        var session = new RegionalPresetSession(this, stage, context);
        var result = await new RegionalPresetService().ApplyAsync(session, maintenance.Token);
        if (result.Status == RegionalPresetStatus.RuntimeFailed && !result.FilesRestored && session.CoreResult is { } failed)
        {
            var data = ToResultDictionary(failed.Data);
            data["rolledBack"] = false;
            data["geoFilesRolledBack"] = false;
            return failed with { Data = data };
        }
        if (result.Status is RegionalPresetStatus.Applied or RegionalPresetStatus.RuntimeFailed)
            return session.CoreResult ?? OperationView.Fail("regional_preset_failed", ApiMessageKeys.RegionalPresetFailed);
        if (result.Status == RegionalPresetStatus.Conflict)
            return OperationView.Fail("regional_preset_conflict", ApiMessageKeys.RegionalPresetFailed,
                new { preset = stage.Preset.ToString(), reason = "configuration_changed_during_staging", retryRequired = true });
        if (result.Status == RegionalPresetStatus.FilesFailed && result.Rollback is { } rollback)
            return OperationView.Fail("regional_preset_failed", ApiMessageKeys.RegionalPresetFailed, new
            {
                preset = stage.Preset.ToString(),
                rolledBack = rollback.RolledBack && result.FilesRestored,
                configAndRuntimeRolledBack = rollback.RolledBack,
                geoFilesRolledBack = result.FilesRestored,
                oldRuntimeRestored = rollback.OldRuntimeRestored,
            });
        return OperationView.Fail("regional_preset_failed", ApiMessageKeys.RegionalPresetFailed);
    }

    private sealed class RegionalPresetSession(V2rayRuntime owner, RegionalPresetStage stage,
        CoreSettingsApplyContext context) : IRegionalPresetSession
    {
        public OperationView? CoreResult { get; private set; }
        public bool IsCurrent => stage.ExpectedState is { } expected
            && expected == ServiceLibRegionalPresetStore.Fingerprint(context.Snapshot!);
        public Task WriteConfigurationAsync(CancellationToken token) => owner._mutations.RunAsync(
            () => new ServiceLibRegionalPresetStore(owner._configStore).ApplyAsync(stage, token), token);
        public async Task<bool> RestoreConfigurationAsync()
        {
            try { await owner._settingsTransaction.RestoreAsync(context); return true; }
            catch (Exception exception) { Log($"Configuration rollback failed: {exception}"); return false; }
        }
        public Task<SettingsRollbackResult> RestoreRuntimeAsync(string reason, bool filesRestored = true) =>
            owner.RollBackCoreSettingsAsync(context, reason, filesRestored ? null :
                () => Task.FromException(new IOException("Regional preset GeoFiles rollback was incomplete.")));
        public Task UpdateFilesAsync(Func<Func<Task>, CancellationToken, Task> beforeCommit, CancellationToken token) =>
            owner.ApplyGeoFilesUpdateAsync(owner.Config.CheckUpdateItem.UpdateViaProxy, token,
                publishProgress: false, beforeCommit: beforeCommit);
        public async Task<bool> ApplyRuntimeAsync(Func<Task> rollbackFiles)
        {
            CoreResult = await owner.CompleteCoreAffectingChangeAsync("regional-preset", true, context,
                ApiMessageKeys.CommonCompleted, new { preset = stage.Preset.ToString() }, beforeRollback: rollbackFiles);
            return CoreResult.Success;
        }
        public bool FilesWereRestored(Exception exception) => exception is not GeoFilesUpdateRollbackException
            && (exception.InnerException is null || FilesWereRestored(exception.InnerException))
            && (exception is not AggregateException aggregate || aggregate.InnerExceptions.All(FilesWereRestored));
        public void Log(string message) => owner.AddLog("settings", $"Regional preset ({stage.Preset}): {message}");
    }
}
