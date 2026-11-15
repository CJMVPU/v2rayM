using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Manager;
using ServiceLib.Models.CoreConfigs;
using ServiceLib.Models.Dto;
using ServiceLib.Services;
using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private sealed class CoreUpdateRunAdapter(V2rayRuntime owner, ECoreType coreType, bool preRelease, bool useProxy) : ICoreUpdateRun
    {
        private CoreUpdateCheckResult? check;
        public bool WasRunning { get; } = owner.IsCoreTypeRunning(coreType);
        public bool IsStopping => owner._operations.IsStopping;
        public async ValueTask<IUpdateOperationLease> EnterStagingAsync() =>
            await owner._operations.EnterOperationAsync(owner._operations.ShutdownToken);
        public async ValueTask<IUpdateOperationLease> EnterApplyAsync() =>
            await owner._operations.EnterExclusiveAsync(owner._operations.ShutdownToken, allowReadOnlyObservations: true);
        public async Task<CoreUpdateCheck> CheckAsync(CancellationToken token)
        {
            check = await owner.CheckCoreUpdateResultAsync(coreType, preRelease, useProxy, token, synchronizePrivileged: true);
            return new(check.Decision switch
            {
                UpdateCheckDecision.Current => UpdateDecision.Current,
                UpdateCheckDecision.Available => UpdateDecision.Available,
                UpdateCheckDecision.AwaitingValidation => UpdateDecision.AwaitingValidation,
                _ => UpdateDecision.Failed,
            }, check.Result.VersionLabel, check.Result.Msg);
        }
        public async Task<ICoreUpdateArtifact> StageAsync(CancellationToken token)
        {
            if (check?.CanStage != true) throw new InvalidOperationException("Only an admitted update may be staged.");
            return await owner.DownloadAndVerifyCoreUpdateAsync(coreType, check.Result, useProxy, token);
        }
        public Task<CoreUpdateApplyResult> ApplyAsync(ICoreUpdateArtifact artifact, CancellationToken token) =>
            owner.ApplyCoreUpdateAsync((CoreUpdateStage)artifact, token);
        public Task DiscardTrustedAsync(ICoreUpdateArtifact artifact) => owner.DiscardPrivilegedStageAsync((CoreUpdateStage)artifact);
        public void CleanupLocal(ICoreUpdateArtifact artifact) => owner.CleanupCoreUpdateStage((CoreUpdateStage)artifact);
        public void Publish(CoreUpdateRunProgress progress) => owner.PublishCoreUpdateProgress(coreType, progress.Phase switch
        {
            CoreUpdateRunPhase.Checking => "checking",
            CoreUpdateRunPhase.Completed => "completed",
            CoreUpdateRunPhase.AwaitingValidation => "awaiting-validation",
            CoreUpdateRunPhase.Failed => "failed",
            _ => throw new ArgumentOutOfRangeException(nameof(progress)),
        }, progress.Phase != CoreUpdateRunPhase.Checking, progress.Success, progress.CoreWasRunning, progress.Version, progress.Detail);
        public void Log(string message) => owner.AddLog("update", $"{coreType}: {message}");
    }

    private sealed class CorePackageStaging : ICorePackageStaging<CoreUpdateStage>
    {
        private readonly V2rayRuntime owner;
        private readonly ECoreType coreType;
        private readonly UpdateResult check;
        private readonly bool useProxy, batch;
        private readonly string installPath, archivePath, packagePath;
        private string? privilegedToken, stagedExecutable;
        private CoreInfo? coreInfo;
        public CorePackageStaging(V2rayRuntime owner, ECoreType coreType, UpdateResult check, bool useProxy, bool batch)
        {
            this.owner = owner; this.coreType = coreType; this.check = check; this.useProxy = useProxy; this.batch = batch;
            installPath = Path.GetFullPath(Utils.GetBinPath(string.Empty, coreType.ToString()));
            var parent = Path.GetDirectoryName(installPath)
                ?? throw new InvalidOperationException($"The {coreType} installation path has no parent directory.");
            archivePath = Utils.GetTempPath($"core-update-{coreType}-{Guid.NewGuid():N}{GetArchiveSuffix(check.Url!)}");
            packagePath = Path.Combine(parent, $".{coreType}-package-{Guid.NewGuid():N}");
        }
        public async Task DownloadAsync(CancellationToken cancellationToken)
        {
            Directory.CreateDirectory(packagePath);
            owner.PublishCoreUpdateProgress(coreType, "downloading", isComplete: false, success: false, owner.IsCoreTypeRunning(coreType), check.VersionLabel, check.Url, batch);
            var download = new DownloadService();
            var downloadFailure = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
            download.Error += (_, args) => downloadFailure.TrySetResult(args.GetException());
            download.ProgressChanged += (_, transfer) =>
                owner.PublishCoreUpdateProgress(coreType, "downloading", false, false, owner.IsCoreTypeRunning(coreType), check.VersionLabel, null, batch, transfer);
            download.UpdateCompleted += (_, progress) =>
            {
                owner.PublishCoreUpdateProgress(coreType, "downloading", isComplete: false, success: false, owner.IsCoreTypeRunning(coreType), check.VersionLabel, progress.Msg, batch);
            };
            await download.DownloadFileAsync(new FileDownloadRequest
            {
                FileUrl = check.Url!,
                FilePath = archivePath,
                DisplayFileName = Path.GetFileName(archivePath),
            },
            useProxy,
            cancellationToken);

            if (downloadFailure.Task.IsCompletedSuccessfully)
            {
                throw new IOException("The core package download failed.", await downloadFailure.Task);
            }
            if (!File.Exists(archivePath))
            {
                throw new IOException("The core package download did not produce an archive.");
            }

        }
        public async Task ExtractAsync(CancellationToken cancellationToken)
        {
            owner.PublishCoreUpdateProgress(coreType, "verifying", isComplete: false, success: false, owner.IsCoreTypeRunning(coreType), check.VersionLabel, null, batch);
            await CoreUpdatePackageStager.ExtractAsync(coreType, archivePath, packagePath, cancellationToken);
            coreInfo = CoreInfoManager.Instance.GetCoreInfo(coreType)
                ?? throw new InvalidOperationException($"{coreType} version metadata is unavailable.");
            stagedExecutable = FindCoreExecutable(coreInfo, packagePath)
                ?? throw new InvalidDataException($"The downloaded {coreType} archive does not contain a usable executable.");
            await Utils.SetLinuxChmod(stagedExecutable);
        }
        public async Task AuthenticateAsync(CancellationToken token)
        {
            if (OperatingSystem.IsMacOS() && coreType == ECoreType.Xray)
            {
                owner.PublishCoreUpdateProgress(coreType, "staging-privileged", false, false, owner.IsCoreTypeRunning(coreType), check.VersionLabel, null, batch);
                privilegedToken = await owner._macTunLauncher.StageUpdateAsync(coreType, archivePath, check.Url!, token);
            }
        }
        public Task<string> VerifyExecutableAsync(CancellationToken token) =>
            owner.VerifyCoreExecutableAsync(coreType,
                coreInfo ?? throw new InvalidOperationException("Core metadata was not extracted."),
                stagedExecutable ?? throw new InvalidOperationException("Core executable was not extracted."), token);
        public CoreUpdateStage Complete(string version) => new(coreType, installPath, archivePath, packagePath, version, privilegedToken);
        public Task DiscardTrustedAsync() => privilegedToken is null ? Task.CompletedTask
            : owner._macTunLauncher.TransitionUpdateAsync(coreType, privilegedToken, "update-discard", CancellationToken.None);
        public void CleanupLocal() => owner.CleanupCoreUpdateStageFiles(archivePath, packagePath);
        public void Log(string message) => owner.AddLog("update", message);
    }
}
