using V2rayM.Domain.Backups;
using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Backups;

public enum BackupRestoreStatus { Started, InvalidArchive, IncompatibleDatabase, PreflightRejected, SafetyBackupFailed, Failed }
public sealed record BackupRestoreResult(BackupRestoreStatus Status, string? SafetyBackup = null);
public interface IRestoreLease : IAsyncDisposable { CancellationToken Token { get; } }
public interface IBackupRestoreSession
{
    ValueTask<IRestoreLease> EnterAsync(CancellationToken token);
    Task<BackupRestoreStatus?> ValidateAsync();
    RestoreAdmission CheckRestart();
    void AcceptRestartPlan();
    Task<IBackupArtifact?> CreateSafetyBackupAsync();
    RuntimeRestartIntent CaptureIntent();
    Task WriteIntentAsync(RuntimeRestartIntent intent);
    Task StopCoreAsync(CancellationToken token);
    Task FlushStateAsync(CancellationToken token);
    Task CloseDatabaseAsync();
    void ReplaceConfiguration();
    void RequestRestart();
    Task DeleteIntentAsync();
    Task RecoverRuntimeAsync(RuntimeRestartIntent intent);
    void DeleteStaging();
    void DeleteArchive();
    void Log(string message);
}

public sealed class BackupRestoreService(IBackupRestoreSession session)
{
    public async Task<BackupRestoreResult> RestoreAsync(CancellationToken token)
    {
        IRestoreLease? lease = null;
        RuntimeRestartIntent? intent = null;
        var intentAttempted = false;
        var runtimeTouched = false;
        var databaseCloseAttempted = false;
        try
        {
            lease = await session.EnterAsync(token);
            token = lease.Token;
            token.ThrowIfCancellationRequested();
            var invalid = await session.ValidateAsync();
            if (invalid is not null) return new(invalid.Value);
            token.ThrowIfCancellationRequested();
            var admission = session.CheckRestart();
            if (!admission.CanProceed) return new(BackupRestoreStatus.PreflightRejected);
            session.AcceptRestartPlan();
            token.ThrowIfCancellationRequested();
            var safety = await session.CreateSafetyBackupAsync();
            if (safety is null) return new(BackupRestoreStatus.SafetyBackupFailed);
            token.ThrowIfCancellationRequested();
            intent = session.CaptureIntent();
            intentAttempted = true;
            await session.WriteIntentAsync(intent);
            token.ThrowIfCancellationRequested();
            runtimeTouched = true;
            await session.StopCoreAsync(token);
            await session.FlushStateAsync(token);
            token.ThrowIfCancellationRequested();
            databaseCloseAttempted = true;
            await session.CloseDatabaseAsync();
            // Once connections are closed, complete the directory transaction and
            // hand recovery to a new host even if the original request is canceled.
            session.ReplaceConfiguration();
            session.RequestRestart();
            return new(BackupRestoreStatus.Started, safety.Name);
        }
        catch (Exception failure)
        {
            ApplicationDiagnostics.Report(session.Log, $"Restore failed: {failure}");
            if (databaseCloseAttempted)
            {
                try { session.RequestRestart(); }
                catch (Exception restart) { ApplicationDiagnostics.Report(session.Log, $"Restore host restart request failed: {restart}"); }
            }
            else if (intentAttempted)
            {
                try { await session.DeleteIntentAsync(); }
                catch (Exception cleanup) { ApplicationDiagnostics.Report(session.Log, $"Restore intent cleanup failed: {cleanup}"); }
                if (runtimeTouched && intent is not null)
                {
                    try { await session.RecoverRuntimeAsync(intent); }
                    catch (Exception recovery) { ApplicationDiagnostics.Report(session.Log, $"Restore runtime recovery failed: {recovery}"); }
                }
            }
            return new(BackupRestoreStatus.Failed);
        }
        finally
        {
            try { session.DeleteStaging(); }
            catch (Exception failure) { ApplicationDiagnostics.Report(session.Log, $"Restore staging cleanup failed: {failure}"); }
            try { session.DeleteArchive(); }
            catch (Exception failure) { ApplicationDiagnostics.Report(session.Log, $"Restore archive cleanup failed: {failure}"); }
            if (lease is not null)
            {
                try { await lease.DisposeAsync(); }
                catch (Exception failure) { ApplicationDiagnostics.Report(session.Log, $"Restore lease release failed: {failure}"); }
            }
        }
    }
}
