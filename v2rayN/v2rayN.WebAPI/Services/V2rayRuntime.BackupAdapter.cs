using ServiceLib.Common;
using ServiceLib.Helper;
using ServiceLib.Manager;
using V2rayM.Application.Backups;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    // The upstream singleton replaces/disposes its client on every operation.
    // Check, upload and download must not overlap even across restore admission.
    private readonly SemaphoreSlim _webDavTransferGate = new(1, 1);
    private async Task<T> RunWebDavTransferAsync<T>(Func<Task<T>> transfer, CancellationToken token)
    {
        await _webDavTransferGate.WaitAsync(token);
        try { token.ThrowIfCancellationRequested(); return await transfer(); }
        finally { _webDavTransferGate.Release(); }
    }
    private sealed record BackupArtifact(string Path) : IBackupArtifact
    {
        public string Name => System.IO.Path.GetFileName(Path);
    }
    private sealed class BackupUploadAdapter(V2rayRuntime owner) : IBackupUpload
    {
        public Task<BackupArchiveResult> CreateAsync() => owner.CreateBackupArtifactAsync();
        public async Task<bool> UploadAsync(IBackupArtifact artifact)
        {
            return await owner.RunWebDavTransferAsync(async () =>
            {
                var success = await WebDavManager.Instance.PutFile(((BackupArtifact)artifact).Path);
                if (!success) Log(WebDavManager.Instance.GetLastError());
                return success;
            }, owner._operations.ShutdownToken);
        }
        public void DeleteLocal(IBackupArtifact artifact)
        {
            var path = ((BackupArtifact)artifact).Path;
            if (File.Exists(path)) File.Delete(path);
        }
        public void Log(string message) => owner.AddLog("backup", message);
    }
    private sealed class BackupArchiveSession(V2rayRuntime owner) : IBackupArchiveSession
    {
        private readonly string archivePath = Utils.GetBackupPath($"backup_{DateTime.UtcNow:yyyyMMddHHmmss}_{Guid.NewGuid():N}.zip");
        private readonly string snapshotPath = Utils.GetTempPath($"backup_{Utils.GetGuid(false)}");
        public async Task FlushAsync()
        {
            await EnsureConfigSaveSucceededAsync(() => owner._configStore.SaveAsync());
            await ProfileExManager.Instance.SaveTo();
            await StatisticsManager.Instance.SaveTo();
        }
        public Task CaptureAsync() => BackupConfigSnapshot.CaptureAsync(Utils.GetConfigPath(), Path.Combine(snapshotPath, "guiConfigs"),
            SQLiteHelper.Instance.BackupAsync);
        public bool CreateArchive() => FileUtils.CreateFromDirectory(snapshotPath, archivePath);
        public long ArchiveSize => new FileInfo(archivePath).Length;
        public IBackupArtifact Artifact => new BackupArtifact(archivePath);
        public void DeleteArchive() { if (File.Exists(archivePath)) File.Delete(archivePath); }
        public void DeleteSnapshot() { if (Directory.Exists(snapshotPath)) Directory.Delete(snapshotPath, recursive: true); }
        public void Log(string message) => owner.AddLog("backup", message);
    }
}
