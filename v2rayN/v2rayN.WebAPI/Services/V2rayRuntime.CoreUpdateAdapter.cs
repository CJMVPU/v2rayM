using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Entities;
using V2rayM.Application.Runtime;
using V2rayM.Application.Updates;
using V2rayM.Domain.Runtime;
using V2rayM.Domain.Updates;
using v2rayN.WebAPI.MacOS;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private sealed class CoreUpdateSession : ICoreUpdateSession
    {
        private readonly V2rayRuntime owner;
        private readonly CoreUpdateStage stage;
        private readonly bool batch;
        private readonly string installPath, candidatePath, backupPath;
        private readonly bool hadInstalledCore;
        private ProfileItem? runningProfile;

        public CoreUpdateSession(V2rayRuntime owner, CoreUpdateStage stage, bool batch)
        {
            this.owner = owner; this.stage = stage; this.batch = batch;
            installPath = stage.InstallPath;
            var parent = Path.GetDirectoryName(installPath)
                ?? throw new InvalidOperationException("The Core installation path has no parent directory.");
            candidatePath = Path.Combine(parent, $".{stage.CoreType}-candidate-{Guid.NewGuid():N}");
            backupPath = Path.Combine(parent, $".{stage.CoreType}-backup-{Guid.NewGuid():N}");
            hadInstalledCore = Directory.Exists(installPath);
            TargetWasRunning = owner.IsCoreTypeRunning(stage.CoreType)
                || stage.PrivilegedToken is not null && owner.Config.TunModeItem.EnableTun
                    && owner.CurrentCoreRuntime.State == CoreRuntimeState.Running && owner.HasTrackedCoreProcesses;
        }
        public string TargetName => stage.CoreType.ToString();
        public string Version => stage.VersionOutput;
        public bool TargetWasRunning { get; }
        public bool HasTrustedStage => stage.PrivilegedToken is not null;
        public bool CandidateInstalled { get; private set; }
        public bool HasBackup => Directory.Exists(backupPath);
        public async Task<bool> CaptureRunningProfileAsync()
        {
            runningProfile = await owner._mutations.RunAsync(() =>
                ConfigDbQuery.GetProfileItem(owner.CurrentCoreRuntime.ProfileId ?? string.Empty));
            return runningProfile is not null;
        }
        public async Task PrepareCandidateAsync(CancellationToken cancellationToken)
        {
            if (hadInstalledCore)
            {
                CopyCoreDirectory(installPath, candidatePath);
            }
            else
            {
                Directory.CreateDirectory(candidatePath);
            }
            foreach (var packageFile in Directory.EnumerateFiles(stage.PackagePath, "*", SearchOption.TopDirectoryOnly))
            {
                cancellationToken.ThrowIfCancellationRequested();
                File.Copy(packageFile, Path.Combine(candidatePath, Path.GetFileName(packageFile)), overwrite: true);
            }
            if (stage.CoreType == ECoreType.Xray)
            {
                CopyLatestGeoFilesForApply(installPath, candidatePath);
            }

            var coreInfo = CoreInfoManager.Instance.GetCoreInfo(stage.CoreType)
                ?? throw new InvalidOperationException($"{stage.CoreType} version metadata is unavailable.");
            RemoveSupersededCoreExecutables(coreInfo, candidatePath, stage.PackagePath);
            var candidateExecutable = FindCoreExecutable(coreInfo, candidatePath)
                ?? throw new InvalidDataException($"The prepared {stage.CoreType} directory has no executable.");
            await Utils.SetLinuxChmod(candidateExecutable);
            await owner.VerifyCoreExecutableAsync(stage.CoreType, coreInfo, candidateExecutable, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

        }
        public async Task StopCoreAsync(CancellationToken token)
        {
            owner.SetCoreRuntime(owner.CurrentCoreRuntime with { State = CoreRuntimeState.Stopping, LastFailure = null });
            await owner.StopCoreMonitorAsync();
            await owner.StopCoreAndConfirmAsync(token);
            owner.SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
        }
        public Task ActivateTrustedAsync(CancellationToken token) => owner._macTunLauncher.TransitionUpdateAsync(
            stage.CoreType, stage.PrivilegedToken, "update-activate", token);
        public Task InstallCandidateAsync()
        {
            if (hadInstalledCore) Directory.Move(installPath, backupPath);
            try { Directory.Move(candidatePath, installPath); CandidateInstalled = true; }
            catch
            {
                if (hadInstalledCore && Directory.Exists(backupPath) && !Directory.Exists(installPath))
                    Directory.Move(backupPath, installPath);
                throw;
            }
            return Task.CompletedTask;
        }
        public async Task InitializeCoreAsync(bool verifyExecutable)
        {
            await CoreManager.Instance.Init(owner.Config, owner.OnCoreMessageAsync);
            if (stage.CoreType == ECoreType.Xray)
            {
                owner._xrayPath = FindXrayExecutable(out var missing);
                if (verifyExecutable && owner._xrayPath is null) throw new InvalidDataException(missing);
            }
        }
        public async Task<RuntimeStartResult> StartCoreAsync(CancellationToken token)
        {
            if (runningProfile is null) throw new InvalidOperationException("The serving profile was not captured for update recovery.");
            var result = await owner.StartCoreLockedAsync(runningProfile, token);
            return new(result.Success, result.Code);
        }
        public Task CommitTrustedAsync(CancellationToken token) => owner._macTunLauncher.TransitionUpdateAsync(
            stage.CoreType, stage.PrivilegedToken, "update-finish", token);
        public async Task<TrustedRollbackDisposition> RollbackTrustedAsync()
        {
            try
            {
                await owner._macTunLauncher.TransitionUpdateAsync(stage.CoreType, stage.PrivilegedToken, "update-rollback", CancellationToken.None);
                return TrustedRollbackDisposition.Restored;
            }
            catch (MacHelperUpdateException exception) when (exception.Code == "update_already_committed")
            { return TrustedRollbackDisposition.AlreadyCommitted; }
        }
        public Task RestoreFilesAsync()
        {
            CoreUpdateFiles.RestorePreviousDirectory(installPath, backupPath, CandidateInstalled, hadInstalledCore);
            return Task.CompletedTask;
        }
        public void CleanupBackup() { if (Directory.Exists(backupPath)) Directory.Delete(backupPath, recursive: true); }
        public void CleanupCandidate() { if (Directory.Exists(candidatePath)) Directory.Delete(candidatePath, recursive: true); }
        public void ReportPhase(CoreUpdateApplyPhase phase, bool restoring = false)
        {
            var name = phase switch
            {
                CoreUpdateApplyPhase.Stopping => "stopping-core",
                CoreUpdateApplyPhase.Installing => "installing",
                CoreUpdateApplyPhase.Restarting => "restarting-core",
                _ => throw new ArgumentOutOfRangeException(nameof(phase)),
            };
            owner.PublishCoreUpdateProgress(stage.CoreType, name, false, false, TargetWasRunning,
                restoring ? null : stage.VersionOutput, restoring ? "Restarting the restored Core."
                    : phase == CoreUpdateApplyPhase.Stopping && !TargetWasRunning ? "The updated Core was not running and will remain stopped." : null, batch);
        }
        public void MarkInterruptedRuntimeFaulted(string detail)
        {
            if (owner.CurrentCoreRuntime.State is CoreRuntimeState.Starting or CoreRuntimeState.Stopping or CoreRuntimeState.Restarting)
                SetFaulted(detail);
        }
        public void MarkRecoveryFailed(string detail)
        {
            Log($"Recovery did not complete; backup location: {backupPath}");
            SetFaulted(detail);
        }
        private void SetFaulted(string detail) => owner.SetCoreRuntime(owner.CurrentCoreRuntime with
        { State = CoreRuntimeState.Faulted, ProcessIds = owner.GetActiveCoreProcessIds(), LastFailure = detail });
        public void Log(string detail) => owner.AddLog("update", $"{stage.CoreType}: {detail}");
    }
}
