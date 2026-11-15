using V2rayM.Application.Updates;

namespace v2rayN.WebAPI.Tests;

public class GeoUpdateRunApplicationTests
{
    [Test]
    public async Task FailedServingReloadRestoresRulesAndRecoversWithoutCancellationWhileLeaseIsOwned()
    {
        var runtime = new Runtime { WasRunning = true, FailFirstRestart = true, ThrowProgress = GeoUpdatePhase.RollingBack };
        await new GeoUpdateRunService().RunAsync(runtime);
        await runtime.Calls.SequenceEqual(new[] { "enter", "files", "restart", "rollback", "recover", "release" }).Should().BeTrue();
        await runtime.Progress.Last().Should().BeEqualTo(GeoUpdatePhase.Failed);
        await runtime.RecoveryToken.CanBeCanceled.Should().BeFalse();
    }
    [Test]
    public async Task StoppedIntentDoesNotStartCoreAndCommittedUpdateIsNotUndoneByPublicationFailure()
    {
        var runtime = new Runtime { ThrowProgress = GeoUpdatePhase.Completed };
        await new GeoUpdateRunService().RunAsync(runtime);
        await runtime.Calls.SequenceEqual(new[] { "enter", "files", "release" }).Should().BeTrue();
        await runtime.Progress.Contains(GeoUpdatePhase.Failed).Should().BeFalse();
        await runtime.Progress.Last().Should().BeEqualTo(GeoUpdatePhase.Completed);
    }
    [Test]
    public async Task FailedFileRollbackDoesNotRestartUsingUnconfirmedRules()
    {
        var runtime = new Runtime { WasRunning = true, FailFirstRestart = true, FailRollback = true };
        await new GeoUpdateRunService().RunAsync(runtime);
        await runtime.Calls.Contains("recover").Should().BeFalse();
        await runtime.Progress.Last().Should().BeEqualTo(GeoUpdatePhase.Failed);
        await runtime.Calls.Last().Should().BeEqualTo("release");
    }
    [Test]
    public async Task CanceledAdmissionNeverDownloadsAndReleasesLease()
    {
        var runtime = new Runtime { IsStopping = true };
        runtime.Cancellation.Cancel();
        await new GeoUpdateRunService().RunAsync(runtime);
        await runtime.Calls.SequenceEqual(new[] { "enter", "release" }).Should().BeTrue();
        await runtime.Progress.Last().Should().BeEqualTo(GeoUpdatePhase.Failed);
    }
    private sealed class Runtime : IGeoUpdateRun
    {
        public bool IsStopping { get; set; }
        public bool WasRunning { get; set; }
        public bool FailFirstRestart, FailRollback;
        public GeoUpdatePhase? ThrowProgress;
        public List<string> Calls = [];
        public List<GeoUpdatePhase> Progress = [];
        public CancellationTokenSource Cancellation = new();
        public CancellationToken RecoveryToken;
        private bool leased;
        private int restarts;
        public ValueTask<IUpdateOperationLease> EnterAsync() { Calls.Add("enter"); leased = true; return ValueTask.FromResult<IUpdateOperationLease>(new Lease(this)); }
        public async Task ApplyFilesAsync(Func<Func<Task>, CancellationToken, Task>? beforeCommit, CancellationToken token)
        {
            Calls.Add("files");
            if (beforeCommit is not null) await beforeCommit(() =>
            { Calls.Add("rollback"); if (FailRollback) throw new IOException("rollback failed"); return Task.CompletedTask; }, token);
        }
        public Task<bool> RestartAsync(CancellationToken token)
        {
            if (!leased) throw new Exception("Maintenance lease required");
            restarts++; Calls.Add(restarts == 1 ? "restart" : "recover");
            if (restarts > 1) RecoveryToken = token;
            return Task.FromResult(!FailFirstRestart || restarts > 1);
        }
        public void Publish(GeoUpdatePhase phase, string? detail = null)
        { Progress.Add(phase); if (phase == ThrowProgress) throw new IOException("progress unavailable"); }
        public void Log(string message) { }
        private sealed class Lease(Runtime owner) : IUpdateOperationLease
        {
            public CancellationToken Token => owner.Cancellation.Token;
            public ValueTask DisposeAsync() { owner.Calls.Add("release"); owner.leased = false; return ValueTask.CompletedTask; }
        }
    }
}
