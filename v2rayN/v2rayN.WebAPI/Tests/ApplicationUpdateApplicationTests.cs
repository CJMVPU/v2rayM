using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;

namespace v2rayN.WebAPI.Tests;

public class ApplicationUpdateApplicationTests
{
    [Test]
    [Arguments("intent")]
    [Arguments("plan")]
    [Arguments("launch")]
    public async Task FailedHandoffBeforeOwnershipCleansBothMarkersAndKeepsHostRunning(string fail)
    {
        var handoff = new Handoff { Fail = fail, CleanupFails = true };
        var error = await FailureAsync(() => new ApplicationUpdateHandoffService(handoff).ExecuteAsync(CancellationToken.None));
        await error.Message.Should().BeEqualTo(fail);
        await handoff.Actions.Contains("delete-intent").Should().BeTrue();
        await handoff.Actions.Contains("delete-plan").Should().BeTrue();
        await handoff.Actions.Contains("stop").Should().BeFalse();
    }

    [Test]
    public async Task NotificationAndLogFailuresAfterLaunchCannotDeleteRecoveryOrPreventShutdown()
    {
        var handoff = new Handoff { Fail = "publish", LogFails = true };
        await new ApplicationUpdateHandoffService(handoff).ExecuteAsync(CancellationToken.None);
        await handoff.Actions.SequenceEqual(["intent", "plan", "launch", "publish", "stop"]).Should().BeTrue();
        await handoff.OwnershipTransferred.Should().BeTrue();
    }

    [Test]
    [Arguments("acknowledgement")]
    [Arguments("stop")]
    public async Task FailureAfterOwnershipPreservesHelperFilesAndRequestsShutdown(string fail)
    {
        var handoff = new Handoff { Fail = fail };
        var error = await FailureAsync(() => new ApplicationUpdateHandoffService(handoff).ExecuteAsync(CancellationToken.None));
        await error.Message.Should().BeEqualTo(fail);
        await handoff.OwnershipTransferred.Should().BeTrue();
        await handoff.Actions.Contains("stop").Should().BeTrue();
        await handoff.Actions.Any(action => action.StartsWith("delete")).Should().BeFalse();
    }

    [Test]
    public async Task CancellationWhileWritingPlanCleansMarkersWithoutLaunching()
    {
        using var source = new CancellationTokenSource();
        var handoff = new Handoff { CancelAfterPlan = source };
        var error = await FailureAsync(() => new ApplicationUpdateHandoffService(handoff).ExecuteAsync(source.Token));
        await (error is OperationCanceledException).Should().BeTrue();
        await handoff.Actions.SequenceEqual(["intent", "plan", "delete-intent", "delete-plan"]).Should().BeTrue();
    }

    [Test]
    public async Task UnacknowledgedOwnershipCannotStopHostOrClaimHandoff()
    {
        var handoff = new Handoff { DeclineOwnership = true };
        await FailureAsync(() => new ApplicationUpdateHandoffService(handoff).ExecuteAsync(CancellationToken.None));
        await handoff.Actions.Contains("stop").Should().BeFalse();
        await handoff.Actions.Contains("delete-plan").Should().BeTrue();
    }

    [Test]
    [Arguments("download")]
    [Arguments("verify")]
    [Arguments("candidate")]
    [Arguments("complete")]
    public async Task PackageFailureCleansAllPartialResourcesWithoutMaskingFailure(string fail)
    {
        var staging = new Staging { Fail = fail, CleanupFails = true };
        var error = await FailureAsync(async () => await new ApplicationPackageStagingService<string>(staging).StageAsync(CancellationToken.None));
        await error.Message.Should().BeEqualTo(fail);
        await staging.Actions.Last().Should().BeEqualTo("cleanup");
        if (fail == "verify") await staging.Actions.Contains("candidate").Should().BeFalse();
    }

    [Test]
    [Arguments("verify")]
    [Arguments("candidate")]
    public async Task CancellationAfterVerificationOrCopyCannotTransferCandidate(string cancelAt)
    {
        using var source = new CancellationTokenSource();
        var staging = new Staging { Cancel = source, CancelAt = cancelAt };
        var error = await FailureAsync(async () => await new ApplicationPackageStagingService<string>(staging).StageAsync(source.Token));
        await (error is OperationCanceledException).Should().BeTrue();
        await staging.Actions.Contains("complete").Should().BeFalse();
        await staging.Actions.Last().Should().BeEqualTo("cleanup");
    }

    [Test]
    public async Task VerifiedPackageTransfersCleanupResponsibilityToCaller()
    {
        var staging = new Staging();
        await (await new ApplicationPackageStagingService<string>(staging).StageAsync(CancellationToken.None)).Should().BeEqualTo("artifact");
        await staging.Actions.SequenceEqual(["download", "verify", "candidate", "complete"]).Should().BeTrue();
    }

    [Test]
    [Arguments(UpdateDecision.Current, ApplicationUpdatePhase.Completed)]
    [Arguments(UpdateDecision.Failed, ApplicationUpdatePhase.Failed)]
    [Arguments(UpdateDecision.AwaitingValidation, ApplicationUpdatePhase.AwaitingValidation)]
    [Arguments((UpdateDecision)999, ApplicationUpdatePhase.Failed)]
    public async Task OnlyAvailableCandidateMayStage(UpdateDecision decision, ApplicationUpdatePhase expected)
    {
        var runtime = new Runtime { Decision = decision };
        await new ApplicationUpdateService(runtime).RunAsync();
        await runtime.Actions.SequenceEqual(["enter", "check", "release"]).Should().BeTrue();
        await runtime.Progress.Last().Should().BeEqualTo(expected);
    }

    [Test]
    public async Task HandoffDoesNotClaimCompletionAndAlwaysReleasesStaging()
    {
        var runtime = new Runtime { CleanupFails = true };
        await new ApplicationUpdateService(runtime).RunAsync();
        await runtime.Actions.SequenceEqual(["enter", "check", "stage", "handoff", "release", "cleanup"]).Should().BeTrue();
        await runtime.Progress.SequenceEqual([ApplicationUpdatePhase.Checking]).Should().BeTrue();
    }

    [Test]
    public async Task MissingArtifactFailsExplicitly()
    {
        var runtime = new Runtime { MissingArtifact = true };
        await new ApplicationUpdateService(runtime).RunAsync();
        await runtime.Actions.Contains("handoff").Should().BeFalse();
        await runtime.Progress.Last().Should().BeEqualTo(ApplicationUpdatePhase.Failed);
    }

    [Test]
    public async Task ShutdownAfterStagingPreventsHandoffAndStillCleansArtifact()
    {
        using var source = new CancellationTokenSource();
        var runtime = new Runtime { CancelAfterStage = source };
        await new ApplicationUpdateService(runtime).RunAsync();
        await runtime.Actions.Contains("handoff").Should().BeFalse();
        await runtime.Actions.Last().Should().BeEqualTo("cleanup");
        await runtime.Detail.Should().BeEqualTo("Canceled during graceful shutdown.");
    }

    private static async Task<Exception> FailureAsync(Func<Task> action)
    {
        try { await action(); }
        catch (Exception failure) { return failure; }
        throw new InvalidOperationException("Expected failure did not occur.");
    }
    private sealed class Handoff : IApplicationUpdateHandoff
    {
        public string? Fail;
        public bool CleanupFails, LogFails, DeclineOwnership;
        public CancellationTokenSource? CancelAfterPlan;
        public List<string> Actions = [];
        public bool OwnershipTransferred { get; private set; }
        private void Step(string action) { Actions.Add(action); if (Fail == action) throw new IOException(action); }
        public Task WriteIntentAsync() { Step("intent"); return Task.CompletedTask; }
        public Task WritePlanAsync() { Step("plan"); CancelAfterPlan?.Cancel(); return Task.CompletedTask; }
        public void LaunchHelper()
        {
            Step("launch"); OwnershipTransferred = !DeclineOwnership;
            if (Fail == "acknowledgement") throw new IOException("acknowledgement");
        }
        public void PublishStopping() => Step("publish");
        public void StopHost() => Step("stop");
        public Task DeleteIntentAsync() { Step("delete-intent"); if (CleanupFails) throw new IOException("cleanup"); return Task.CompletedTask; }
        public void DeletePlan() { Step("delete-plan"); if (CleanupFails) throw new IOException("cleanup"); }
        public void Log(string message) { if (LogFails || CleanupFails) throw new IOException("log"); }
    }
    private sealed class Staging : IApplicationPackageStaging<string>
    {
        public string? Fail, CancelAt;
        public bool CleanupFails;
        public CancellationTokenSource? Cancel;
        public List<string> Actions = [];
        private void Step(string action)
        {
            Actions.Add(action);
            if (Fail == action) throw new IOException(action);
            if (CancelAt == action) Cancel?.Cancel();
        }
        public Task DownloadAsync(CancellationToken token) { Step("download"); return Task.CompletedTask; }
        public Task VerifyAsync(CancellationToken token) { Step("verify"); return Task.CompletedTask; }
        public void PrepareCandidate() => Step("candidate");
        public string Complete() { Step("complete"); return "artifact"; }
        public void Cleanup() { Step("cleanup"); if (CleanupFails) throw new IOException("cleanup"); }
        public void Log(string message) => throw new IOException("log");
    }
    private sealed class Runtime : IApplicationUpdateRuntime
    {
        public bool CleanupFails, MissingArtifact;
        public UpdateDecision Decision = UpdateDecision.Available;
        public CancellationTokenSource? CancelAfterStage;
        public bool IsStopping => CancelAfterStage?.IsCancellationRequested == true;
        public List<string> Actions = [];
        public List<ApplicationUpdatePhase> Progress = [];
        public string? Detail;
        public ValueTask<IUpdateOperationLease> EnterAsync() { Actions.Add("enter"); return ValueTask.FromResult<IUpdateOperationLease>(new Lease(this)); }
        public Task<ApplicationUpdateCheck> CheckAsync(CancellationToken token) { Actions.Add("check"); return Task.FromResult(new ApplicationUpdateCheck(Decision, "next", null)); }
        public Task<IApplicationUpdateArtifact> StageAsync(CancellationToken token)
        {
            Actions.Add("stage"); CancelAfterStage?.Cancel();
            return Task.FromResult<IApplicationUpdateArtifact>(MissingArtifact ? null! : new Artifact());
        }
        public Task HandoffAsync(IApplicationUpdateArtifact artifact, CancellationToken token) { Actions.Add("handoff"); return Task.CompletedTask; }
        public void Cleanup(IApplicationUpdateArtifact artifact) { Actions.Add("cleanup"); if (CleanupFails) throw new IOException("cleanup"); }
        public void Publish(ApplicationUpdatePhase phase, string? version, string? detail) { Progress.Add(phase); Detail = detail; }
        public void Log(string message) => throw new IOException("log");
        private sealed class Artifact : IApplicationUpdateArtifact { public string Version => "next"; }
        private sealed class Lease(Runtime owner) : IUpdateOperationLease
        {
            public CancellationToken Token => owner.CancelAfterStage?.Token ?? CancellationToken.None;
            public ValueTask DisposeAsync() { owner.Actions.Add("release"); return ValueTask.CompletedTask; }
        }
    }
}
