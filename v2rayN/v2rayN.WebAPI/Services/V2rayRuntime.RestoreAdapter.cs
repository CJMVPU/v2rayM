using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Helper;
using ServiceLib.Manager;
using V2rayM.Application.Backups;
using V2rayM.Domain.Backups;
using V2rayM.Domain.Runtime;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.Launcher;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private sealed class RestoreInput(V2rayRuntime owner, string archivePath, Stream? upload = null) : IRestoreInput
    {
        public bool IsStopping => owner._operations.IsStopping;
        public async ValueTask<IRestoreLease> EnterAsync(CancellationToken token) =>
            new RestoreOperationLease(await owner._operations.EnterOperationAsync(token));
        public async Task<bool> ReceiveAsync(CancellationToken token)
        {
            if (upload is not null)
            {
                await using var output = new FileStream(archivePath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                await CopyWithLimitAsync(upload, output, MaxBackupArchiveBytes, token);
                return true;
            }
            return await owner.RunWebDavTransferAsync(async () =>
            {
                // The upstream client has no cancellation parameter. Retain both
                // operation and transport ownership until its download finishes.
                var received = await WebDavManager.Instance.GetRawFile(archivePath);
                if (!received) Log(WebDavManager.Instance.GetLastError());
                return received;
            }, token);
        }
        public void DeleteArchive() { if (File.Exists(archivePath)) File.Delete(archivePath); }
        public void Log(string message) => owner.AddLog("backup", message);
    }
    private sealed class RestoreOperationLease(RuntimeOperationCoordinator.Lease lease) : IRestoreLease
    {
        public CancellationToken Token => lease.Token;
        public ValueTask DisposeAsync() => lease.DisposeAsync();
    }
    private sealed class BackupRestoreSession(V2rayRuntime owner, string archivePath) : IBackupRestoreSession
    {
        private readonly string stagingRoot = Utils.GetTempPath($"restore_stage_{Utils.GetGuid(false)}");
        private NativeWebRestorePreflightResult? preflight;
        private bool statisticsCloseAttempted;
        public async ValueTask<IRestoreLease> EnterAsync(CancellationToken token) =>
            new RestoreOperationLease(await owner._operations.EnterExclusiveAsync(token));
        public Task<BackupRestoreStatus?> ValidateAsync()
        {
            if (!IsSafeBackupArchive(archivePath)) return Task.FromResult<BackupRestoreStatus?>(BackupRestoreStatus.InvalidArchive);
            Directory.CreateDirectory(stagingRoot);
            if (!TryExtractBackupConfig(archivePath, stagingRoot) || !IsValidBackupConfig(Path.Combine(stagingRoot, Global.ConfigFileName)))
                return Task.FromResult<BackupRestoreStatus?>(BackupRestoreStatus.InvalidArchive);
            try { RestoreDatabaseSnapshot.Normalize(stagingRoot); }
            catch (Exception failure) when (failure is SQLite.SQLiteException or IOException or UnauthorizedAccessException)
            {
                Log($"Restore database snapshot rejected: {failure.Message}");
                return Task.FromResult<BackupRestoreStatus?>(BackupRestoreStatus.IncompatibleDatabase);
            }
            var databasePath = Path.Combine(stagingRoot, "guiNDB.db");
            if (File.Exists(databasePath) && !BackupDatabaseCompatibility.IsCompatible(databasePath, out var error))
            {
                Log($"Restore preflight rejected database: {error}");
                return Task.FromResult<BackupRestoreStatus?>(BackupRestoreStatus.IncompatibleDatabase);
            }
            return Task.FromResult<BackupRestoreStatus?>(null);
        }
        public RestoreAdmission CheckRestart()
        {
            owner._nativeRestoreReplacement = null;
            preflight = owner.EvaluateNativeRestorePreflight();
            return new(preflight.Allowed, preflight.Owner == WebLifecycleOwner.NativeProcess, preflight.Replacement is not null);
        }
        public void AcceptRestartPlan() => owner._nativeRestoreReplacement = preflight?.Replacement;
        public OperationView PreflightFailure() => preflight is { Allowed: false } ? preflight.ToFailureOperation()
            : OperationView.Fail("backup_restore_failed", ApiMessageKeys.BackupRestoreFailed);
        public async Task<IBackupArtifact?> CreateSafetyBackupAsync()
        {
            var result = await owner.CreateBackupArtifactAsync();
            return result.Status == BackupArchiveStatus.Created ? result.Artifact : null;
        }
        public RuntimeRestartIntent CaptureIntent()
        {
            var current = owner.CurrentCoreRuntime;
            return new(current.State == CoreRuntimeState.Running, current.ProfileId);
        }
        public Task WriteIntentAsync(RuntimeRestartIntent intent) => WriteRestoreRuntimeStateAsync(intent);
        public async Task StopCoreAsync(CancellationToken token)
        {
            owner.SetCoreRuntime(owner.CurrentCoreRuntime with { State = CoreRuntimeState.Stopping, LastFailure = null });
            await owner.StopCoreMonitorAsync();
            await owner.StopCoreAndConfirmAsync(token);
            owner.SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
        }
        public async Task FlushStateAsync(CancellationToken token)
        {
            await ProfileExManager.Instance.SaveTo();
            statisticsCloseAttempted = true;
            await StatisticsManager.Instance.CloseAsync();
            await owner._mutations.RunAsync(() => EnsureConfigSaveSucceededAsync(() => owner._configStore.SaveAsync()), token);
        }
        public Task CloseDatabaseAsync() => SQLiteHelper.Instance.DisposeDbConnectionAsync();
        public void ReplaceConfiguration()
        {
            var configPath = Utils.GetConfigPath();
            var parent = Path.GetDirectoryName(configPath) ?? throw new InvalidOperationException("Configuration has no parent directory.");
            var candidate = Path.Combine(parent, $".guiConfigs-restore-{Guid.NewGuid():N}");
            var displaced = Path.Combine(parent, $".guiConfigs-before-restore-{Guid.NewGuid():N}");
            RestoreDirectoryTransaction.Apply(
                () => PrepareRestoredConfigDirectory(stagingRoot, configPath, candidate),
                () => ReplaceConfigDirectory(candidate, configPath, displaced),
                () => owner.TryDeleteRestoreDirectory(candidate, "restore candidate"),
                () => owner.TryDeleteRestoreDirectory(displaced, "displaced configuration"));
        }
        public void RequestRestart()
        {
            owner._restoring = true;
            owner._operations.RejectNewOperations();
            owner.RequestHostShutdownForRestore();
        }
        public Task DeleteIntentAsync() => CommitRestoreRuntimeStateAsync(RestoreRuntimeStatePath);
        public async Task RecoverRuntimeAsync(RuntimeRestartIntent intent)
        {
            try
            {
                var remaining = owner.GetActiveCoreProcessIds();
                if (!intent.WasRunning && remaining.Length == 0) owner.SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
                await RecoverRuntimeAfterFailedRestoreAsync(intent,
                    remaining, (ids, failure) => owner.SetCoreRuntime(owner.CurrentCoreRuntime with
                    { State = CoreRuntimeState.Faulted, ProcessIds = ids, LastFailure = failure }), owner.StartCoreAsync,
                    Log, CancellationToken.None);
            }
            finally
            {
                // Core recovery does not recreate the statistics sampler stopped
                // by restore. The database remains open on this recovery path.
                if (statisticsCloseAttempted) await StatisticsManager.Instance.Init(owner.Config, owner.OnStatisticsUpdateAsync, owner.GetStatisticsPort);
            }
        }
        public void DeleteStaging() { if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true); }
        public void DeleteArchive() { if (File.Exists(archivePath)) File.Delete(archivePath); }
        public void Log(string message) => owner.AddLog("backup", message);
    }
}
