using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;

namespace v2rayN.WebAPI.Tests;

public class UpdateBatchApplicationTests
{
    private static readonly BatchUpdateTarget[] Targets = [new("First", BatchTargetKind.Core), new("Second", BatchTargetKind.Core),
        new("Rules", BatchTargetKind.GeoFiles), new("App", BatchTargetKind.Application)];

    [Test]
    public async Task StagesEveryCoreBeforeRulesAndApplicationThenAppliesBeforeHandoff()
    {
        var runtime = new Runtime();
        await new UpdateBatchService(runtime).RunAsync(Targets, true);
        await runtime.Actions.SequenceEqual(["enter", "check:First", "check:Second", "check:App", "stage:First", "stage:Second",
            "geo", "stage:App", "apply:First", "apply:Second", "reload", "handoff", "release",
            "discard:First", "cleanup:First", "discard:Second", "cleanup:Second", "discard:App", "cleanup:App"]).Should().BeTrue();
        await runtime.Completed.Count.Should().BeEqualTo(0);
        await runtime.Progress["App"].Phase.Should().BeEqualTo("checking");
        await runtime.Progress["Rules"].Success.Should().BeTrue();
    }

    [Test]
    [Arguments("stage:First")]
    [Arguments("stage:Second")]
    [Arguments("geo")]
    [Arguments("stage:App")]
    public async Task FailedPreparationPreventsEveryCoreApplyAndFinishesEveryTarget(string fail)
    {
        var runtime = new Runtime { Fail = fail };
        await new UpdateBatchService(runtime).RunAsync(Targets, true);
        await runtime.Actions.Any(action => action.StartsWith("apply:")).Should().BeFalse();
        await runtime.Actions.Contains("handoff").Should().BeFalse();
        await runtime.Completed.SequenceEqual([(false, true)]).Should().BeTrue();
        await runtime.Progress.Count.Should().BeEqualTo(4);
        await runtime.Progress.Values.All(progress => progress.Complete).Should().BeTrue();
        foreach (var artifact in runtime.Staged)
            await runtime.Actions.Contains("cleanup:" + artifact).Should().BeTrue();
    }

    [Test]
    [Arguments(UpdateDecision.Failed)]
    [Arguments((UpdateDecision)999)]
    public async Task FailedOrUnknownCheckFinishesPendingApplicationAndDoesNotDownload(UpdateDecision decision)
    {
        var runtime = new Runtime();
        runtime.Checks["First"] = new(decision, null, "check failed");
        await new UpdateBatchService(runtime).RunAsync(Targets, true);
        await runtime.Staged.Count.Should().BeEqualTo(0);
        await runtime.Progress.Values.All(progress => progress.Complete).Should().BeTrue();
        await runtime.Progress["App"].Success.Should().BeFalse();
        await runtime.Completed.SequenceEqual([(false, true)]).Should().BeTrue();
    }

    [Test]
    public async Task CheckOnlyDoesNotSynchronizeOrStageAndRetainsAwaitingValidation()
    {
        var runtime = new Runtime();
        runtime.Checks["First"] = new(UpdateDecision.AwaitingValidation, "next", "unapproved");
        runtime.Checks["App"] = new(UpdateDecision.Available, "next", null, false, "unsupported");
        await new UpdateBatchService(runtime).RunAsync(Targets, false);
        await runtime.CheckApply.Any(value => value).Should().BeFalse();
        await runtime.Staged.Count.Should().BeEqualTo(0);
        await runtime.Progress["First"].Phase.Should().BeEqualTo("awaiting-validation");
        await runtime.Progress["App"].Success.Should().BeTrue();
        await runtime.Completed.SequenceEqual([(false, false)]).Should().BeTrue();
    }

    [Test]
    public async Task CurrentAwaitingAndUnsupportedTargetsDoNotBlockAdmittedIndependentTargets()
    {
        var runtime = new Runtime();
        runtime.Checks["First"] = new(UpdateDecision.Current, "old", null);
        runtime.Checks["Second"] = new(UpdateDecision.AwaitingValidation, "new", null);
        runtime.Checks["App"] = new(UpdateDecision.Available, "new", null, false, "unsupported");
        await new UpdateBatchService(runtime).RunAsync(Targets, true);
        await runtime.Staged.Count.Should().BeEqualTo(0);
        await runtime.Actions.Contains("geo").Should().BeTrue();
        await runtime.Actions.Contains("reload").Should().BeTrue();
        await runtime.Completed.SequenceEqual([(false, true)]).Should().BeTrue();
    }

    [Test]
    [Arguments(true)]
    [Arguments(false)]
    public async Task SuccessfulRunningCoreApplyAvoidsDuplicateRuleReloadButFailureDoesNot(bool applySuccess)
    {
        var runtime = new Runtime { ApplySuccess = applySuccess, AppliedRunningCore = true };
        await new UpdateBatchService(runtime).RunAsync(Targets[..3], true);
        await runtime.Actions.Contains("reload").Should().BeEqualTo(!applySuccess);
        await runtime.Progress["First"].CoreWasRunning.Should().BeEqualTo(true);
        await runtime.Completed.SequenceEqual([(applySuccess, true)]).Should().BeTrue();
    }

    [Test]
    public async Task StructuredApplyFailureStillProcessesOtherTargetsWithoutClaimingBatchSuccess()
    {
        var runtime = new Runtime { ApplySuccess = false };
        await new UpdateBatchService(runtime).RunAsync(Targets[..3], true);
        await runtime.Actions.Contains("apply:Second").Should().BeTrue();
        await runtime.Completed.SequenceEqual([(false, true)]).Should().BeTrue();
    }

    [Test]
    [Arguments("enter")]
    [Arguments("stage:Second")]
    [Arguments("apply:First")]
    [Arguments("reload")]
    [Arguments("handoff")]
    public async Task ShutdownCancellationTerminatesPendingWorkAndReleasesOwnedPackages(string fail)
    {
        var runtime = new Runtime { Fail = fail, IsStopping = true };
        await new UpdateBatchService(runtime).RunAsync(Targets, true);
        await runtime.Completed.SequenceEqual([(false, true)]).Should().BeTrue();
        await runtime.Progress.Values.All(progress => progress.Complete).Should().BeTrue();
        foreach (var artifact in runtime.Staged)
            await runtime.Actions.Contains("cleanup:" + artifact).Should().BeTrue();
    }

    [Test]
    public async Task CleanupAndDiagnosticFailureDoNotSkipOtherPackagesOrChangeSuccessfulResult()
    {
        var runtime = new Runtime { CleanupFails = true };
        await new UpdateBatchService(runtime).RunAsync(Targets[..2], true);
        await runtime.Actions.Contains("cleanup:Second").Should().BeTrue();
        await runtime.Completed.SequenceEqual([(true, true)]).Should().BeTrue();
    }

    private sealed class Runtime : IUpdateBatchRuntime
    {
        public string? Fail;
        public bool IsStopping { get; init; }
        public bool CoreRunning => true;
        public bool ApplySuccess = true, AppliedRunningCore, CleanupFails;
        public List<string> Actions = [], Staged = [];
        public List<bool> CheckApply = [];
        public List<(bool, bool)> Completed = [];
        public Dictionary<string, BatchUpdateCheck> Checks = [];
        public Dictionary<string, BatchUpdateProgress> Progress = [];
        private void Step(string step)
        {
            Actions.Add(step);
            if (step == Fail)
            {
                if (IsStopping) throw new OperationCanceledException();
                throw new InvalidOperationException(step);
            }
        }
        public ValueTask<IUpdateOperationLease> EnterAsync() { Step("enter"); return ValueTask.FromResult<IUpdateOperationLease>(new Lease(this)); }
        public Task<BatchUpdateCheck> CheckAsync(BatchUpdateTarget target, bool apply, CancellationToken token)
        {
            Step("check:" + target.Id); CheckApply.Add(apply);
            return Task.FromResult(Checks.GetValueOrDefault(target.Id) ?? new(UpdateDecision.Available, "next", null));
        }
        public Task<IBatchUpdateArtifact> StageAsync(BatchUpdateTarget target, CancellationToken token)
        {
            Step("stage:" + target.Id); Staged.Add(target.Id);
            return Task.FromResult<IBatchUpdateArtifact>(new Artifact(target.Id));
        }
        public Task<CoreUpdateApplyResult> ApplyCoreAsync(IBatchUpdateArtifact artifact, CancellationToken token)
        {
            Step("apply:" + ((Artifact)artifact).Id);
            return Task.FromResult(new CoreUpdateApplyResult(ApplySuccess, !ApplySuccess, AppliedRunningCore, "applied"));
        }
        public Task ApplyGeoAsync(CancellationToken token) { Step("geo"); return Task.CompletedTask; }
        public Task<bool> ReloadGeoAsync(CancellationToken token) { Step("reload"); return Task.FromResult(true); }
        public Task HandoffApplicationAsync(IBatchUpdateArtifact artifact, CancellationToken token) { Step("handoff"); return Task.CompletedTask; }
        public Task DiscardAsync(IBatchUpdateArtifact artifact)
        {
            Step("discard:" + ((Artifact)artifact).Id);
            if (CleanupFails) throw new IOException("discard failed");
            return Task.CompletedTask;
        }
        public void Cleanup(IBatchUpdateArtifact artifact)
        {
            Step("cleanup:" + ((Artifact)artifact).Id);
            if (CleanupFails) throw new IOException("cleanup failed");
        }
        public void Publish(BatchUpdateTarget target, BatchUpdateProgress progress) => Progress[target.Id] = progress;
        public void Complete(bool success, bool apply) => Completed.Add((success, apply));
        public void Log(string message) { if (CleanupFails) throw new IOException("log failed"); }
        private sealed record Artifact(string Id) : IBatchUpdateArtifact { public string Version => "next"; }
        private sealed class Lease(Runtime owner) : IUpdateOperationLease
        {
            public CancellationToken Token => CancellationToken.None;
            public ValueTask DisposeAsync() { owner.Step("release"); return ValueTask.CompletedTask; }
        }
    }
}
