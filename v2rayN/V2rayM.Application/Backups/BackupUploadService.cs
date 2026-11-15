namespace V2rayM.Application.Backups;

public interface IBackupUpload
{
    Task<BackupArchiveResult> CreateAsync();
    Task<bool> UploadAsync(IBackupArtifact artifact);
    void DeleteLocal(IBackupArtifact artifact);
    void Log(string message);
}
public enum BackupUploadStatus { Uploaded, CreationFailed, UploadFailed }
public sealed record BackupUploadResult(BackupUploadStatus Status, BackupArchiveStatus? CreationStatus = null, string? FileName = null);

public sealed class BackupUploadService(IBackupUpload remote)
{
    public async Task<BackupUploadResult> UploadAsync()
    {
        var created = await remote.CreateAsync();
        if (created.Status != BackupArchiveStatus.Created || created.Artifact is null)
            return new(BackupUploadStatus.CreationFailed, created.Status);
        var artifact = created.Artifact;
        try
        {
            return await remote.UploadAsync(artifact)
                ? new(BackupUploadStatus.Uploaded, FileName: artifact.Name)
                : new(BackupUploadStatus.UploadFailed);
        }
        catch (Exception failure)
        {
            BackupDiagnostics.Report(remote.Log, $"Remote backup failed: {failure}");
            return new(BackupUploadStatus.UploadFailed);
        }
        finally
        {
            try { remote.DeleteLocal(artifact); }
            catch (Exception failure) { BackupDiagnostics.Report(remote.Log, $"Uploaded backup cleanup failed: {failure}"); }
        }
    }
}
