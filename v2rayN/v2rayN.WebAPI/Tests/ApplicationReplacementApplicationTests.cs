using V2rayM.Application.Updates;

namespace v2rayN.WebAPI.Tests;

public class ApplicationReplacementApplicationTests
{
    [Test]
    [Arguments(true)]
    [Arguments(false)]
    public async Task CleanupAndNotificationFailuresCannotUndoHealthyReplacementOrRecovery(bool candidateHealthy)
    {
        var runtime = new Replacement { CandidateHealthy = candidateHealthy, CleanupFails = true, NotificationFails = true };
        var result = await new ApplicationReplacementService(runtime).ApplyAsync();
        await result.Success.Should().BeEqualTo(candidateHealthy);
        await result.RollbackSucceeded.Should().BeEqualTo(!candidateHealthy);
        await runtime.Actions.Count(action => action == "restore").Should().BeEqualTo(candidateHealthy ? 0 : 1);
        await runtime.Actions.Last().Should().BeEqualTo("cleanup");
    }

    [Test]
    public async Task PartialRestoreWithResponsiveOldProcessDoesNotClaimRecoveryOrDeleteEvidence()
    {
        var runtime = new Replacement { CandidateHealthy = false, RestoreFails = true };
        var result = await new ApplicationReplacementService(runtime).ApplyAsync();
        await result.Success.Should().BeFalse();
        await result.RollbackSucceeded.Should().BeFalse();
        await result.Detail.Should().Contain("restore incomplete");
        await runtime.Actions.Contains("previous").Should().BeTrue();
        await runtime.Actions.Contains("cleanup").Should().BeFalse();
    }

    [Test]
    public async Task FailedReplacementAndFailedRecoveryPreserveBackup()
    {
        var runtime = new Replacement { InstallFails = true, PreviousHealthy = false };
        var result = await new ApplicationReplacementService(runtime).ApplyAsync();
        await result.RollbackSucceeded.Should().BeFalse();
        await runtime.Actions.SequenceEqual(["install", "restore", "previous"]).Should().BeTrue();
        await result.Detail.Should().Contain("install failed");
    }

    private sealed class Replacement : IApplicationReplacement
    {
        public bool CandidateHealthy = true, PreviousHealthy = true, CleanupFails, NotificationFails, RestoreFails, InstallFails;
        public List<string> Actions = [];
        public Task InstallAsync() { Actions.Add("install"); if (InstallFails) throw new IOException("install failed"); return Task.CompletedTask; }
        public Task<bool> StartAndVerifyCandidateAsync() { Actions.Add("candidate"); return Task.FromResult(CandidateHealthy); }
        public Task RestoreFilesAsync() { Actions.Add("restore"); if (RestoreFails) throw new IOException("restore incomplete"); return Task.CompletedTask; }
        public Task<bool> StartAndVerifyPreviousAsync() { Actions.Add("previous"); return Task.FromResult(PreviousHealthy); }
        public Task CleanupAsync() { Actions.Add("cleanup"); if (CleanupFails) throw new IOException("cleanup failed"); return Task.CompletedTask; }
        public void Publish(ApplicationReplacementPhase phase) { if (NotificationFails) throw new IOException("progress failed"); }
        public void Log(string message) => throw new IOException("log failed");
    }
}
