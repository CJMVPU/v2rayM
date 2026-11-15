using V2rayM.Application.Runtime;
using V2rayM.Domain.Updates;

namespace V2rayM.Application.Updates;

public enum CoreUpdateApplyPhase { Stopping, Installing, Restarting }
public sealed record CoreUpdateApplyResult(bool Success, bool RolledBack, bool CoreWasRunning,
    string Detail, string? Version = null, bool AwaitingValidation = false);
public sealed record CoreUpdateRollbackResult(bool FilesRestored, bool CoreRestarted, bool UpdateCommitted = false)
{
    public bool Completed => !UpdateCommitted && FilesRestored && CoreRestarted;
}

public interface ICoreUpdateSession
{
    string TargetName { get; }
    string Version { get; }
    bool TargetWasRunning { get; }
    bool HasTrustedStage { get; }
    bool CandidateInstalled { get; }
    bool HasBackup { get; }
    Task<bool> CaptureRunningProfileAsync();
    Task PrepareCandidateAsync(CancellationToken token);
    Task StopCoreAsync(CancellationToken token);
    Task ActivateTrustedAsync(CancellationToken token);
    Task InstallCandidateAsync();
    Task InitializeCoreAsync(bool verifyExecutable);
    Task<RuntimeStartResult> StartCoreAsync(CancellationToken token);
    Task CommitTrustedAsync(CancellationToken token);
    Task<TrustedRollbackDisposition> RollbackTrustedAsync();
    Task RestoreFilesAsync();
    void CleanupBackup();
    void CleanupCandidate();
    void ReportPhase(CoreUpdateApplyPhase phase, bool restoring = false);
    void MarkInterruptedRuntimeFaulted(string detail);
    void MarkRecoveryFailed(string detail);
    void Log(string detail);
}

/// The caller owns lifecycle serialization and maintenance admission until apply
/// and compensation complete. Recovery never uses the canceled request token.
public sealed class CoreUpdateApplyService
{
    public const string CommittedUpdateUnconfirmedDetail =
        "The new Core was already committed and has been retained in both update stores. " +
        "Final acknowledgement was interrupted; runtime health still requires confirmation. No rollback was performed.";

    public async Task<CoreUpdateApplyResult> ApplyAsync(ICoreUpdateSession session, CancellationToken token)
    {
        var stopped = false;
        var trustedActivationRequested = false;
        UpdateRecoveryState RecoveryState() => new(stopped, session.CandidateInstalled, trustedActivationRequested, session.HasBackup);
        CoreUpdateApplyResult Committed() => new(false, false, session.TargetWasRunning, CommittedUpdateUnconfirmedDetail, session.Version);
        try
        {
            if (session.TargetWasRunning && !await session.CaptureRunningProfileAsync())
                return new(false, false, true, "The active profile could not be loaded; the running Core was left unchanged.");
            // Candidate verification is offline and precedes interruption of the
            // serving process. Package download/authentication already completed.
            await session.PrepareCandidateAsync(token);
            token.ThrowIfCancellationRequested();
            session.ReportPhase(CoreUpdateApplyPhase.Stopping);
            if (session.TargetWasRunning)
            {
                await session.StopCoreAsync(token);
                stopped = true;
            }
            // Activation can succeed before its acknowledgement is lost. Once
            // sent, require trusted rollback confirmation before local recovery.
            trustedActivationRequested = session.HasTrustedStage;
            await session.ActivateTrustedAsync(token);
            session.ReportPhase(CoreUpdateApplyPhase.Installing);
            await session.InstallCandidateAsync();
            await session.InitializeCoreAsync(verifyExecutable: true);
            if (session.TargetWasRunning)
            {
                session.ReportPhase(CoreUpdateApplyPhase.Restarting);
                var started = await session.StartCoreAsync(token);
                if (!started.Success) throw new InvalidOperationException($"The updated {session.TargetName} failed to restart ({started.Code}).");
            }
            await session.CommitTrustedAsync(token);
            trustedActivationRequested = false;
            TryCleanup(session.CleanupBackup, session, "Previous Core cleanup deferred");
            return new(true, false, session.TargetWasRunning, "Update installed and verified.", session.Version);
        }
        catch (OperationCanceledException exception)
        {
            session.MarkInterruptedRuntimeFaulted(exception.Message);
            if (RecoveryState().RequiresRecovery)
            {
                var rollback = await RestoreAsync(session, RecoveryState());
                if (rollback.UpdateCommitted) return Committed();
                if (!rollback.Completed) ApplicationDiagnostics.Report(session.Log, rollback.FilesRestored
                    ? "Previous files were restored, but the old Core process could not be relaunched."
                    : "Rollback did not complete; the previous files were retained for recovery.");
            }
            throw;
        }
        catch (Exception exception)
        {
            ApplicationDiagnostics.Report(session.Log, $"Apply failed: {exception.Message}");
            session.MarkInterruptedRuntimeFaulted(exception.Message);
            if (!RecoveryState().RequiresRecovery)
                return new(false, false, session.TargetWasRunning, $"{exception.Message} No replacement was applied.", session.Version);
            var rollback = await RestoreAsync(session, RecoveryState());
            if (rollback.UpdateCommitted) return Committed();
            var detail = rollback.Completed ? $"{exception.Message} The previous Core was restored."
                : rollback.FilesRestored ? $"{exception.Message} The previous Core files were restored, but its process could not be restarted."
                : $"{exception.Message} Rollback did not complete; see the runtime log for the retained backup path.";
            return new(false, rollback.Completed, session.TargetWasRunning, detail, session.Version);
        }
        finally { TryCleanup(session.CleanupCandidate, session, "Candidate cleanup failed"); }
    }

    public async Task<CoreUpdateRollbackResult> RestoreAsync(ICoreUpdateSession session, UpdateRecoveryState state)
    {
        var filesRestored = false;
        try
        {
            if (state.TrustedActivationRequested)
            {
                var trusted = await session.RollbackTrustedAsync();
                if (trusted == TrustedRollbackDisposition.AlreadyCommitted)
                {
                    ApplicationDiagnostics.Report(session.Log, CommittedUpdateUnconfirmedDetail);
                    return new(false, false, UpdateCommitted: true);
                }
                if (trusted != TrustedRollbackDisposition.Restored)
                    throw new InvalidOperationException("Unknown trusted rollback disposition; local files were not changed.");
            }
            // An idle target must not stop an unrelated runtime. Trusted rollback
            // confirmation precedes any local replacement or process restart.
            if (state.CoreStopped && session.TargetWasRunning) await session.StopCoreAsync(CancellationToken.None);
            await session.RestoreFilesAsync();
            filesRestored = true;
            await session.InitializeCoreAsync(verifyExecutable: false);
            var restarted = true;
            if (session.TargetWasRunning)
            {
                session.ReportPhase(CoreUpdateApplyPhase.Restarting, restoring: true);
                restarted = (await session.StartCoreAsync(CancellationToken.None)).Success;
            }
            return new(filesRestored, restarted);
        }
        catch (Exception exception)
        {
            ApplicationDiagnostics.Report(session.Log, $"Rollback failed: {exception.Message}");
            session.MarkRecoveryFailed(exception.Message);
            return new(filesRestored, false);
        }
    }

    private static void TryCleanup(Action cleanup, ICoreUpdateSession session, string label)
    {
        try { cleanup(); }
        catch (Exception exception) { ApplicationDiagnostics.Report(session.Log, $"{label}: {exception.Message}"); }
    }
}
