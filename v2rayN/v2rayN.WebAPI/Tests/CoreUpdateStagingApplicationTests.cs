using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;

namespace v2rayN.WebAPI.Tests;

public class CoreUpdateStagingApplicationTests
{
    [Test]
    public async Task PackageAuthenticationPrecedesExecutableProbeAndTransfersOwnershipOnlyOnSuccess()
    {
        var staging = new Staging();
        var artifact = await new CorePackageStagingService().StageAsync(staging, default);
        await artifact.Should().BeEqualTo("verified-version");
        await string.Join(",", staging.Calls).Should().BeEqualTo("download,extract,authenticate,verify,complete");
    }

    [Test]
    [Arguments("download")]
    [Arguments("extract")]
    [Arguments("authenticate")]
    [Arguments("verify")]
    [Arguments("complete")]
    public async Task FailedStagingDiscardsTrustedAndLocalStateWithoutMaskingOriginalFailure(string stage)
    {
        var staging = new Staging { FailAt = stage, FailCleanup = true, FailLog = true };
        Exception? failure = null;
        try { await new CorePackageStagingService().StageAsync(staging, default); }
        catch (Exception exception) { failure = exception; }
        await ReferenceEquals(failure, staging.Failure).Should().BeTrue();
        await string.Join(",", staging.Calls.TakeLast(2)).Should().BeEqualTo("discard,cleanup");
        if (stage is "download" or "extract" or "authenticate") await staging.Calls.Contains("verify").Should().BeFalse();
    }

    [Test]
    public async Task CancellationAfterAuthenticationDoesNotRunTheCandidate()
    {
        using var cancel = new CancellationTokenSource();
        var staging = new Staging { CancelAfterAuthentication = cancel };
        var cancelled = false;
        try { await new CorePackageStagingService().StageAsync(staging, cancel.Token); }
        catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await string.Join(",", staging.Calls).Should().BeEqualTo("download,extract,authenticate,discard,cleanup");
    }

    [Test]
    [Arguments(UpdateDecision.Current, CoreUpdateRunPhase.Completed, true)]
    [Arguments(UpdateDecision.AwaitingValidation, CoreUpdateRunPhase.AwaitingValidation, false)]
    [Arguments(UpdateDecision.Failed, CoreUpdateRunPhase.Failed, false)]
    [Arguments((UpdateDecision)999, CoreUpdateRunPhase.Failed, false)]
    public async Task NonAdmittedChecksNeverDownloadOrEnterExclusiveMaintenance(UpdateDecision decision, CoreUpdateRunPhase phase, bool success)
    {
        var run = new Run { Decision = decision };
        await new CoreUpdateRunService().RunAsync(run);
        await run.Progress.Last().Phase.Should().BeEqualTo(phase);
        await run.Progress.Last().Success.Should().BeEqualTo(success);
        await string.Join(",", run.Calls).Should().BeEqualTo("enter-stage,check,leave-stage");
    }

    [Test]
    public async Task StagingLeaseIsReleasedBeforeExclusiveApplyAndArtifactCleanup()
    {
        var run = new Run();
        await new CoreUpdateRunService().RunAsync(run);
        await run.Progress.Last().Success.Should().BeTrue();
        await string.Join(",", run.Calls).Should().BeEqualTo(
            "enter-stage,check,stage,leave-stage,enter-apply,apply,leave-apply,discard,cleanup");
    }

    [Test]
    public async Task ApplyFailureAndCleanupLoggingFailureStillReleaseEveryOwnedResource()
    {
        var run = new Run { FailApply = true, FailDiscard = true, FailLog = true };
        await new CoreUpdateRunService().RunAsync(run);
        await run.Progress.Last().Phase.Should().BeEqualTo(CoreUpdateRunPhase.Failed);
        await run.Progress.Last().Success.Should().BeFalse();
        await string.Join(",", run.Calls.TakeLast(3)).Should().BeEqualTo("leave-apply,discard,cleanup");
    }

    [Test]
    public async Task ShutdownBetweenStagingAndMaintenanceDiscardsTheStagedArtifact()
    {
        var run = new Run { StopBeforeApply = true };
        await new CoreUpdateRunService().RunAsync(run);
        await run.Progress.Last().Detail.Should().BeEqualTo("Canceled during graceful shutdown.");
        await run.Calls.Contains("apply").Should().BeFalse();
        await string.Join(",", run.Calls.TakeLast(2)).Should().BeEqualTo("discard,cleanup");
    }

    [Test]
    public async Task MissingArtifactCannotBecomeAnAlreadyCurrentSuccess()
    {
        var run = new Run { MissingArtifact = true };
        await new CoreUpdateRunService().RunAsync(run);
        await run.Progress.Last().Phase.Should().BeEqualTo(CoreUpdateRunPhase.Failed);
        await run.Calls.Contains("enter-apply").Should().BeFalse();
    }

    [Test]
    public async Task FailedStagingNeverEntersApplyAndReleasesTheSharedLease()
    {
        var run = new Run { FailStage = true };
        await new CoreUpdateRunService().RunAsync(run);
        await run.Progress.Last().Phase.Should().BeEqualTo(CoreUpdateRunPhase.Failed);
        await string.Join(",", run.Calls).Should().BeEqualTo("enter-stage,check,stage,leave-stage");
    }

    [Test]
    public async Task PostCommitCleanupAndDiagnosticFailureNeverTriggerRollback()
    {
        var session = new CoreUpdateTestSession { FailAt = "cleanup-backup", FailLog = true };
        var result = await new CoreUpdateApplyService().ApplyAsync(session, default);
        await result.Success.Should().BeTrue();
        await session.Calls.Contains("rollback-trusted").Should().BeFalse();
        await session.Calls.Last().Should().BeEqualTo("cleanup-candidate");
    }

    private sealed class Staging : ICorePackageStaging<string>
    {
        public string? FailAt;
        public bool FailCleanup, FailLog;
        public CancellationTokenSource? CancelAfterAuthentication;
        public readonly Exception Failure = new InvalidOperationException("original failure");
        public List<string> Calls { get; } = [];
        private void Step(string name) { Calls.Add(name); if (FailAt == name) throw Failure; }
        public Task DownloadAsync(CancellationToken token) { Step("download"); return Task.CompletedTask; }
        public Task ExtractAsync(CancellationToken token) { Step("extract"); return Task.CompletedTask; }
        public Task AuthenticateAsync(CancellationToken token)
        { Step("authenticate"); CancelAfterAuthentication?.Cancel(); return Task.CompletedTask; }
        public Task<string> VerifyExecutableAsync(CancellationToken token) { Step("verify"); return Task.FromResult("verified-version"); }
        public string Complete(string version) { Step("complete"); return version; }
        public Task DiscardTrustedAsync() { Step("discard"); if (FailCleanup) throw new IOException("discard failed"); return Task.CompletedTask; }
        public void CleanupLocal() { Step("cleanup"); if (FailCleanup) throw new IOException("cleanup failed"); }
        public void Log(string message) { if (FailLog) throw new IOException("closed diagnostic pipe"); }
    }

    private sealed class Run : ICoreUpdateRun
    {
        public bool WasRunning => true;
        public bool IsStopping => StopBeforeApply;
        public UpdateDecision Decision = UpdateDecision.Available;
        public bool FailApply, FailDiscard, FailLog, StopBeforeApply, MissingArtifact, FailStage;
        private bool _shared, _exclusive;
        public List<string> Calls { get; } = [];
        public List<CoreUpdateRunProgress> Progress { get; } = [];
        public ValueTask<IUpdateOperationLease> EnterStagingAsync()
        {
            Calls.Add("enter-stage"); _shared = true;
            return ValueTask.FromResult<IUpdateOperationLease>(new Lease(() => { Calls.Add("leave-stage"); _shared = false; }));
        }
        public ValueTask<IUpdateOperationLease> EnterApplyAsync()
        {
            Calls.Add("enter-apply");
            if (_shared) throw new InvalidOperationException("Shared lease was not released");
            if (StopBeforeApply) throw new OperationCanceledException();
            _exclusive = true;
            return ValueTask.FromResult<IUpdateOperationLease>(new Lease(() => { Calls.Add("leave-apply"); _exclusive = false; }));
        }
        public Task<CoreUpdateCheck> CheckAsync(CancellationToken token)
        { if (!_shared) throw new Exception("Missing staging lease"); Calls.Add("check"); return Task.FromResult(new CoreUpdateCheck(Decision, "checked", null)); }
        public Task<ICoreUpdateArtifact> StageAsync(CancellationToken token)
        {
            if (!_shared) throw new Exception("Missing staging lease"); Calls.Add("stage");
            if (FailStage) throw new InvalidDataException("verification failed");
            return Task.FromResult<ICoreUpdateArtifact>(MissingArtifact ? null! : new Artifact());
        }
        public Task<CoreUpdateApplyResult> ApplyAsync(ICoreUpdateArtifact artifact, CancellationToken token)
        {
            if (!_exclusive) throw new Exception("Missing exclusive lease"); Calls.Add("apply");
            if (FailApply) throw new IOException("apply failed");
            return Task.FromResult(new CoreUpdateApplyResult(true, false, true, "installed", artifact.Version));
        }
        public Task DiscardTrustedAsync(ICoreUpdateArtifact artifact)
        {
            if (_shared || _exclusive) throw new Exception("Unexpected retained lease"); Calls.Add("discard");
            if (FailDiscard) throw new IOException("discard failed"); return Task.CompletedTask;
        }
        public void CleanupLocal(ICoreUpdateArtifact artifact) => Calls.Add("cleanup");
        public void Publish(CoreUpdateRunProgress progress) => Progress.Add(progress);
        public void Log(string message) { if (FailLog) throw new IOException("closed diagnostic pipe"); }
        private sealed record Artifact : ICoreUpdateArtifact { public string Version => "verified"; }
        private sealed class Lease(Action release) : IUpdateOperationLease
        {
            public CancellationToken Token => default;
            public ValueTask DisposeAsync() { release(); return ValueTask.CompletedTask; }
        }
    }
}
