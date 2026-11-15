using ServiceLib.Enums;
using ServiceLib.Models.Dto;
using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;
using V2rayM.Domain.Runtime;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private sealed class UpdateBatchAdapter(V2rayRuntime owner, bool useProxy) : IUpdateBatchRuntime
    {
        private readonly Dictionary<string, CoreUpdateCheckResult> coreChecks = new(StringComparer.Ordinal);
        private WebUpdateReleaseCheck? webCheck;
        public bool IsStopping => owner._operations.IsStopping;
        public bool CoreRunning => owner.CurrentCoreRuntime.State == CoreRuntimeState.Running;
        public async ValueTask<IUpdateOperationLease> EnterAsync() => await owner._operations.EnterExclusiveAsync(
            owner._operations.ShutdownToken, allowReadOnlyObservations: true);
        public async Task<BatchUpdateCheck> CheckAsync(BatchUpdateTarget target, bool apply, CancellationToken token)
        {
            if (target.Kind == BatchTargetKind.Application)
            {
                webCheck = await owner.CheckWebUpdateReleaseAsync(owner.GetUpdatePreRelease(WebUpdateTarget), useProxy, token);
                Volatile.Write(ref owner._latestWebUpdateVersion, webCheck.Version);
                return new(!string.IsNullOrEmpty(webCheck.Error) ? UpdateDecision.Failed
                    : webCheck.IsUpdateAvailable ? UpdateDecision.Available : UpdateDecision.Current,
                    webCheck.Version, webCheck.Error ?? webCheck.Detail, owner.CanInstallWebUpdate(), owner.GetWebUpdateInstallReasonKey());
            }
            var core = Enum.Parse<ECoreType>(target.Id);
            var check = await owner.CheckCoreUpdateResultAsync(core, null, useProxy, token, synchronizePrivileged: apply);
            coreChecks[target.Id] = check;
            return new(check.Decision switch
            {
                UpdateCheckDecision.Current => UpdateDecision.Current,
                UpdateCheckDecision.Available => UpdateDecision.Available,
                UpdateCheckDecision.AwaitingValidation => UpdateDecision.AwaitingValidation,
                _ => UpdateDecision.Failed,
            }, check.Result.VersionLabel, check.Result.Msg, owner.CanInstallCoreUpdate(core),
                "This Web deployment can check but cannot safely install this target.");
        }
        public async Task<IBatchUpdateArtifact> StageAsync(BatchUpdateTarget target, CancellationToken token)
        {
            if (target.Kind == BatchTargetKind.Application)
            {
                if (webCheck is null) throw new InvalidOperationException("The application update was not checked.");
                return new BatchArtifact(null, await owner.StageWebUpdateAsync(webCheck, useProxy, token, batch: true), webCheck.Version);
            }
            var stage = await owner.DownloadAndVerifyCoreUpdateAsync(Enum.Parse<ECoreType>(target.Id), coreChecks[target.Id].Result,
                useProxy, token, batch: true);
            return new BatchArtifact(stage, null, stage.VersionOutput);
        }
        public Task<CoreUpdateApplyResult> ApplyCoreAsync(IBatchUpdateArtifact artifact, CancellationToken token) =>
            owner.ApplyCoreUpdateAsync(((BatchArtifact)artifact).Core!, token, batch: true);
        public Task ApplyGeoAsync(CancellationToken token) => owner.ApplyGeoFilesUpdateAsync(useProxy, token, batch: true);
        public async Task<bool> ReloadGeoAsync(CancellationToken token) => (await owner.RestartCoreAsync(token)).Success;
        public Task HandoffApplicationAsync(IBatchUpdateArtifact artifact, CancellationToken token) =>
            owner.ApplyStagedWebUpdateAsync(((BatchArtifact)artifact).Web!, token, batch: true);
        public Task DiscardAsync(IBatchUpdateArtifact artifact) => ((BatchArtifact)artifact).Core is { } core
            ? owner.DiscardPrivilegedStageAsync(core) : Task.CompletedTask;
        public void Cleanup(IBatchUpdateArtifact artifact)
        {
            var stage = (BatchArtifact)artifact;
            if (stage.Web is not null) CleanupWebUpdateStage(stage.Web);
            if (stage.Core is not null) owner.CleanupCoreUpdateStage(stage.Core);
        }
        public void Publish(BatchUpdateTarget target, BatchUpdateProgress progress)
        {
            switch (target.Kind)
            {
                case BatchTargetKind.GeoFiles:
                    owner.PublishGeoUpdateProgress(progress.Phase, progress.Complete, progress.Success, progress.Detail, batch: true);
                    break;
                case BatchTargetKind.Application:
                    owner.PublishWebUpdateProgress(progress.Phase, progress.Complete, progress.Success, progress.Detail, progress.Version, batch: true);
                    break;
                default:
                    var core = Enum.Parse<ECoreType>(target.Id);
                    owner.PublishCoreUpdateProgress(core, progress.Phase, progress.Complete, progress.Success,
                        progress.CoreWasRunning ?? owner.IsCoreTypeRunning(core), progress.Version, progress.Detail, batch: true);
                    break;
            }
        }
        public void Complete(bool success, bool apply) => owner._events.Publish("core-update-batch-completed", new { success, apply });
        public void Log(string message) => owner.AddLog("update", message);
        private sealed record BatchArtifact(CoreUpdateStage? Core, WebUpdateStage? Web, string? Version) : IBatchUpdateArtifact;
    }
}
