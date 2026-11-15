using V2rayM.Domain.Backups;

namespace V2rayM.Application.Backups;

public interface IBackupArtifact { string Name { get; } }
public interface IBackupArchiveSession
{
    Task FlushAsync();
    Task CaptureAsync();
    bool CreateArchive();
    long ArchiveSize { get; }
    IBackupArtifact Artifact { get; }
    void DeleteArchive();
    void DeleteSnapshot();
    void Log(string message);
}
public enum BackupArchiveStatus { Created, Failed, TooLarge }
public sealed record BackupArchiveResult(BackupArchiveStatus Status, IBackupArtifact? Artifact = null);

public sealed class BackupArchiveService(IMutationScope mutations)
{
    // The host/restore caller owns its existing maintenance lease. Taking another
    // one here would deadlock restore's safety backup. Only the snapshot holds the
    // shared write scope; compression works on detached files after it is released.
    public async Task<BackupArchiveResult> CreateAsync(IBackupArchiveSession session)
    {
        var transferred = false;
        try
        {
            await mutations.RunAsync(async () =>
            {
                await session.FlushAsync();
                await session.CaptureAsync();
                return true;
            });
            if (!session.CreateArchive()) return new(BackupArchiveStatus.Failed);
            var size = session.ArchiveSize;
            if (!BackupPolicy.IsValidArchiveSize(size))
                return new(size > BackupPolicy.MaximumArchiveBytes ? BackupArchiveStatus.TooLarge : BackupArchiveStatus.Failed);
            var artifact = session.Artifact ?? throw new InvalidOperationException("Backup creation produced no artifact.");
            transferred = true;
            return new(BackupArchiveStatus.Created, artifact);
        }
        catch (Exception failure)
        {
            BackupDiagnostics.Report(session.Log, $"Backup creation failed: {failure}");
            return new(BackupArchiveStatus.Failed);
        }
        finally
        {
            if (!transferred)
            {
                try { session.DeleteArchive(); }
                catch (Exception failure) { BackupDiagnostics.Report(session.Log, $"Partial backup cleanup failed: {failure}"); }
            }
            try { session.DeleteSnapshot(); }
            catch (Exception failure) { BackupDiagnostics.Report(session.Log, $"Backup snapshot cleanup failed: {failure}"); }
        }
    }
}

internal static class BackupDiagnostics
{
    public static void Report(Action<string> log, string message)
    {
        try { log(message); }
        catch (Exception) { /* Diagnostics cannot prevent resource cleanup. */ }
    }
}
