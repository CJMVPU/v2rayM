using V2rayM.Application.Runtime;
using V2rayM.Application.Updates;
using V2rayM.Domain.Runtime;
using V2rayM.Domain.Updates;

namespace v2rayN.WebAPI.Tests;

public class CoreUpdateApplicationTests
{
    [Test]
    public async Task ApplyVerifiesBeforeStoppingAndCommitsOnlyAfterSuccessfulRestart()
    {
        var session = new CoreUpdateTestSession();
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.Success.Should().BeTrue();
        await result.RolledBack.Should().BeFalse();
        await string.Join(",", session.Calls).Should().BeEqualTo(
            "capture,prepare,stop,activate,install,initialize,start,commit,cleanup-backup,cleanup-candidate");
    }

    [Test]
    public async Task MissingRunningProfileLeavesServingProcessAndFilesUntouched()
    {
        var session = new CoreUpdateTestSession { ProfileFound = false };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.Success.Should().BeFalse();
        await result.RolledBack.Should().BeFalse();
        await string.Join(",", session.Calls).Should().BeEqualTo("capture,cleanup-candidate");
    }

    [Test]
    [Arguments("prepare")]
    [Arguments("stop")]
    public async Task FailureBeforeReplacementIsNotReportedAsSuccessfulRollback(string failure)
    {
        var session = new CoreUpdateTestSession { FailAt = failure };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.Success.Should().BeFalse();
        await result.RolledBack.Should().BeFalse();
        await session.Calls.Contains("restore-files").Should().BeFalse();
        await session.Calls.Contains("install").Should().BeFalse();
        await session.InterruptedMarked.Should().BeTrue();
    }

    [Test]
    [Arguments("activate")]
    [Arguments("install")]
    [Arguments("initialize")]
    [Arguments("start")]
    [Arguments("commit")]
    public async Task FailuresAfterInterruptionRecoverTrustedFilesAndRuntimeInOrder(string failure)
    {
        var session = new CoreUpdateTestSession { FailAt = failure };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.Success.Should().BeFalse();
        await result.RolledBack.Should().BeTrue();
        var recovery = session.Calls.SkipWhile(call => call != "rollback-trusted");
        await string.Join(",", recovery).Should().BeEqualTo(
            "rollback-trusted,stop,restore-files,initialize-old,start,cleanup-candidate");
        await session.Calls.Contains("cleanup-backup").Should().BeFalse();
    }

    [Test]
    public async Task IdleTargetNeverStopsOrStartsAnUnrelatedCore()
    {
        var session = new CoreUpdateTestSession { TargetWasRunning = false, FailAt = "commit" };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.RolledBack.Should().BeTrue();
        await session.Calls.Contains("stop").Should().BeFalse();
        await session.Calls.Contains("start").Should().BeFalse();
    }

    [Test]
    public async Task LostCommitAcknowledgementPreservesMatchingCandidateAndDoesNotClaimHealth()
    {
        var session = new CoreUpdateTestSession { FailAt = "commit", Trusted = TrustedRollbackDisposition.AlreadyCommitted };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.Success.Should().BeFalse();
        await result.RolledBack.Should().BeFalse();
        await result.Detail.Should().Contain("health still requires confirmation");
        await session.Calls.Contains("restore-files").Should().BeFalse();
        await session.Calls.Count(call => call == "stop").Should().BeEqualTo(1);
        await session.Calls.Contains("cleanup-backup").Should().BeFalse();
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task UnknownOrFailedTrustedRollbackPreventsLocalReplacementAndRelaunch(bool unknown)
    {
        var session = new CoreUpdateTestSession
        { FailAt = "activate", FailTrustedRollback = !unknown, Trusted = unknown ? (TrustedRollbackDisposition)999 : TrustedRollbackDisposition.Restored };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.RolledBack.Should().BeFalse();
        await session.RecoveryMarked.Should().BeTrue();
        await session.Calls.Contains("restore-files").Should().BeFalse();
        await session.Calls.Contains("start").Should().BeFalse();
    }

    [Test]
    public async Task CancellationAfterInstallRecoversWithUncancelledTokenThenRethrows()
    {
        using var cancel = new CancellationTokenSource();
        var session = new CoreUpdateTestSession { Cancel = cancel, CancelAt = "initialize" };
        var cancelled = false;
        try { await new CoreUpdateApplyService().ApplyAsync(session, cancel.Token); }
        catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await session.Calls.Contains("restore-files").Should().BeTrue();
        await session.LastStartTokenCanBeCanceled.Should().BeFalse();
        await session.LastStopTokenCanBeCanceled.Should().BeFalse();
    }

    [Test]
    public async Task CancelledStopLeavesAnExplicitFaultInsteadOfAStuckTransition()
    {
        using var cancel = new CancellationTokenSource();
        var session = new CoreUpdateTestSession { Cancel = cancel, CancelAt = "stop" };
        var cancelled = false;
        try { await new CoreUpdateApplyService().ApplyAsync(session, cancel.Token); }
        catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await session.InterruptedMarked.Should().BeTrue();
        await session.Calls.Contains("install").Should().BeFalse();
    }

    [Test]
    public async Task CancellationAfterDurableCommitReportsUnconfirmedInsteadOfRollingBack()
    {
        using var cancel = new CancellationTokenSource();
        var session = new CoreUpdateTestSession
        { Cancel = cancel, CancelAt = "commit", Trusted = TrustedRollbackDisposition.AlreadyCommitted };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, cancel.Token);
        await result.Success.Should().BeFalse();
        await result.RolledBack.Should().BeFalse();
        await result.Detail.Should().Contain("No rollback was performed");
        await session.Calls.Contains("restore-files").Should().BeFalse();
    }

    [Test]
    public async Task PartialDirectorySwapRequiresRecoveryEvenForAnIdleUnprivilegedTarget()
    {
        var session = new CoreUpdateTestSession
        { TargetWasRunning = false, HasTrustedStage = false, PartialSwap = true, FailAt = "install" };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.RolledBack.Should().BeTrue();
        await session.Calls.Contains("restore-files").Should().BeTrue();
        await session.Calls.Contains("rollback-trusted").Should().BeFalse();
        await session.Calls.Contains("stop").Should().BeFalse();
    }

    [Test]
    public async Task FailedFileRecoveryNeverReinitializesOrStartsTheOldCore()
    {
        var session = new CoreUpdateTestSession
        { FailAt = "commit", RestoreFiles = () => throw new IOException("restore-files failed") };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.RolledBack.Should().BeFalse();
        await session.RecoveryMarked.Should().BeTrue();
        await session.Calls.Contains("initialize-old").Should().BeFalse();
        await session.Calls.Count(call => call == "start").Should().BeEqualTo(1);
    }

    [Test]
    public async Task BackupCleanupFailureDoesNotUndoACommittedHealthyUpdate()
    {
        var session = new CoreUpdateTestSession { FailAt = "cleanup-backup" };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.Success.Should().BeTrue();
        await session.Calls.Contains("rollback-trusted").Should().BeFalse();
    }

    [Test]
    [Arguments(CoreRuntimeState.Running, true)]
    [Arguments(CoreRuntimeState.Faulted, true)]
    [Arguments(CoreRuntimeState.Stopped, false)]
    [Arguments(CoreRuntimeState.Starting, false)]
    [Arguments(CoreRuntimeState.Stopping, false)]
    [Arguments(CoreRuntimeState.Restarting, false)]
    public async Task UpdateRunningSelectionRequiresMatchingOwnedProcess(CoreRuntimeState state, bool running)
    {
        await CoreUpdatePolicy.IsTargetRunning(state, true, true).Should().BeEqualTo(running);
        await CoreUpdatePolicy.IsTargetRunning(state, false, true).Should().BeFalse();
        await CoreUpdatePolicy.IsTargetRunning(state, true, false).Should().BeFalse();
    }
}

internal sealed class CoreUpdateTestSession : ICoreUpdateSession
{
    public string TargetName => "Xray";
    public string Version => "v-fixture";
    public bool TargetWasRunning { get; init; } = true;
    public bool HasTrustedStage { get; init; } = true;
    public bool CandidateInstalled { get; set; }
    public bool HasBackup { get; set; }
    public bool ProfileFound = true, FailTrustedRollback, InterruptedMarked, RecoveryMarked;
    public bool PartialSwap, FailLog;
    public bool LastStartTokenCanBeCanceled, LastStopTokenCanBeCanceled;
    public string? FailAt, CancelAt;
    public CancellationTokenSource? Cancel;
    public TrustedRollbackDisposition Trusted = TrustedRollbackDisposition.Restored;
    public Func<Task>? RestoreFiles, InitializeOld;
    public Func<Task<bool>>? RestartOld;
    public List<string> Calls { get; } = [];
    private bool _recovering;
    private void Step(string name)
    {
        Calls.Add(name);
        if (!_recovering && CancelAt == name) { Cancel!.Cancel(); throw new OperationCanceledException(Cancel.Token); }
        if (!_recovering && FailAt == name) throw new IOException(name + " failed");
    }
    public Task<bool> CaptureRunningProfileAsync() { Step("capture"); return Task.FromResult(ProfileFound); }
    public Task PrepareCandidateAsync(CancellationToken token) { Step("prepare"); return Task.CompletedTask; }
    public Task StopCoreAsync(CancellationToken token) { LastStopTokenCanBeCanceled = token.CanBeCanceled; Step("stop"); return Task.CompletedTask; }
    public Task ActivateTrustedAsync(CancellationToken token) { Step("activate"); return Task.CompletedTask; }
    public Task InstallCandidateAsync()
    {
        if (PartialSwap) HasBackup = true;
        Step("install"); CandidateInstalled = HasBackup = true; return Task.CompletedTask;
    }
    public Task InitializeCoreAsync(bool verifyExecutable)
    {
        if (!verifyExecutable) _recovering = true;
        Step(verifyExecutable ? "initialize" : "initialize-old");
        return !verifyExecutable && InitializeOld is not null ? InitializeOld() : Task.CompletedTask;
    }
    public async Task<RuntimeStartResult> StartCoreAsync(CancellationToken token)
    {
        LastStartTokenCanBeCanceled = token.CanBeCanceled; Step("start");
        return new(!_recovering || RestartOld is null || await RestartOld(), "fixture");
    }
    public Task CommitTrustedAsync(CancellationToken token) { Step("commit"); return Task.CompletedTask; }
    public Task<TrustedRollbackDisposition> RollbackTrustedAsync()
    {
        Step("rollback-trusted"); _recovering = true;
        if (FailTrustedRollback) throw new OperationCanceledException("Trusted acknowledgement missing");
        return Task.FromResult(Trusted);
    }
    public Task RestoreFilesAsync() { _recovering = true; Step("restore-files"); return RestoreFiles?.Invoke() ?? Task.CompletedTask; }
    public void CleanupBackup() => Step("cleanup-backup");
    public void CleanupCandidate() => Step("cleanup-candidate");
    public void ReportPhase(CoreUpdateApplyPhase phase, bool restoring = false) { }
    public void MarkInterruptedRuntimeFaulted(string detail) => InterruptedMarked = true;
    public void MarkRecoveryFailed(string detail) => RecoveryMarked = true;
    public void Log(string detail) { if (FailLog) throw new IOException("closed diagnostic pipe"); }
}
