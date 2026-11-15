using V2rayM.Application.Backups;
using V2rayM.Domain.Backups;
using V2rayM.Domain.Runtime;

namespace v2rayN.WebAPI.Tests;

public class BackupRestoreApplicationTests
{
    [Test]
    public async Task ValidRestoreCapturesSafetyCopyBeforeStoppingAndHandsClosedDatabaseToRestart()
    {
        var session = new RestoreTestSession();
        var result = await new BackupRestoreService(session).RestoreAsync(default);
        await result.Status.Should().BeEqualTo(BackupRestoreStatus.Started);
        await result.SafetyBackup.Should().BeEqualTo("safety.zip");
        await session.Actions.SequenceEqual(["enter", "validate", "preflight", "accept", "backup", "capture", "intent", "stop",
            "flush", "close", "replace", "restart", "staging-cleanup", "archive-cleanup", "release"]).Should().BeTrue();
    }

    [Test]
    [Arguments("intent", false, false)]
    [Arguments("stop", true, false)]
    [Arguments("flush", true, false)]
    [Arguments("close", false, true)]
    [Arguments("replace", false, true)]
    [Arguments("restart", false, true)]
    public async Task FailureCompensationFollowsDatabaseOwnershipBoundary(string fail, bool recover, bool restart)
    {
        var session = new RestoreTestSession { Fail = fail };
        var result = await new BackupRestoreService(session).RestoreAsync(default);
        await result.Status.Should().BeEqualTo(BackupRestoreStatus.Failed);
        await session.Actions.Contains("recover").Should().BeEqualTo(recover);
        await session.Actions.Contains("restart").Should().BeEqualTo(restart);
        await session.Actions.Contains("delete-intent").Should().BeEqualTo(!restart);
        await session.Actions.TakeLast(3).SequenceEqual(["staging-cleanup", "archive-cleanup", "release"]).Should().BeTrue();
    }

    [Test]
    [Arguments("flush", BackupRestoreStatus.Failed)]
    [Arguments("close", BackupRestoreStatus.Started)]
    public async Task CancellationBeforeClosureRecoversButAfterClosureFinishesRestart(string cancelAt, BackupRestoreStatus expected)
    {
        using var source = new CancellationTokenSource();
        var session = new RestoreTestSession { CancelAt = cancelAt, Cancellation = source };
        var result = await new BackupRestoreService(session).RestoreAsync(source.Token);
        await result.Status.Should().BeEqualTo(expected);
        await session.Actions.Contains("recover").Should().BeEqualTo(cancelAt == "flush");
        await session.Actions.Contains("replace").Should().BeEqualTo(cancelAt == "close");
    }

    [Test]
    [Arguments(false, true, true)]
    [Arguments(true, true, false)]
    public async Task RefusalOrMissingRequiredRestartPlanCannotStartSafetyBackup(bool allowed, bool requiresPlan, bool hasPlan)
    {
        var session = new RestoreTestSession { Admission = new(allowed, requiresPlan, hasPlan) };
        var result = await new BackupRestoreService(session).RestoreAsync(default);
        await result.Status.Should().BeEqualTo(BackupRestoreStatus.PreflightRejected);
        await session.Actions.Contains("backup").Should().BeFalse();
        await session.Actions.Contains("stop").Should().BeFalse();
    }

    [Test]
    public async Task MissingSafetyBackupCannotWriteIntentOrStopRuntime()
    {
        var session = new RestoreTestSession { NoBackup = true };
        var result = await new BackupRestoreService(session).RestoreAsync(default);
        await result.Status.Should().BeEqualTo(BackupRestoreStatus.SafetyBackupFailed);
        await session.Actions.Contains("intent").Should().BeFalse();
    }

    [Test]
    [Arguments(BackupRestoreStatus.InvalidArchive)]
    [Arguments(BackupRestoreStatus.IncompatibleDatabase)]
    public async Task InvalidInputStopsBeforeRestartPlanning(BackupRestoreStatus status)
    {
        var session = new RestoreTestSession { Invalid = status };
        await (await new BackupRestoreService(session).RestoreAsync(default)).Status.Should().BeEqualTo(status);
        await session.Actions.Contains("preflight").Should().BeFalse();
    }

    [Test]
    public async Task CleanupAndLogFailuresCannotSkipLeaseReleaseOrRevokeCommittedRestore()
    {
        var session = new RestoreTestSession { CleanupFails = true };
        await (await new BackupRestoreService(session).RestoreAsync(default)).Status.Should().BeEqualTo(BackupRestoreStatus.Started);
        await session.Actions.TakeLast(3).SequenceEqual(["staging-cleanup", "archive-cleanup", "release"]).Should().BeTrue();
    }
}

internal sealed class RestoreTestSession : IBackupRestoreSession
{
    public List<string> Actions = [];
    public string? Fail, CancelAt;
    public CancellationTokenSource? Cancellation;
    public bool NoBackup, CleanupFails;
    public BackupRestoreStatus? Invalid;
    public RestoreAdmission Admission = new(true, false, false);
    private void Step(string action)
    {
        Actions.Add(action);
        if (action == CancelAt) Cancellation?.Cancel();
        if (action == Fail || CleanupFails && action.EndsWith("cleanup")) throw new IOException(action);
    }
    public ValueTask<IRestoreLease> EnterAsync(CancellationToken token) { Step("enter"); return ValueTask.FromResult<IRestoreLease>(new Lease(this, token)); }
    public Task<BackupRestoreStatus?> ValidateAsync() { Step("validate"); return Task.FromResult(Invalid); }
    public RestoreAdmission CheckRestart() { Step("preflight"); return Admission; }
    public void AcceptRestartPlan() => Step("accept");
    public Task<IBackupArtifact?> CreateSafetyBackupAsync() { Step("backup"); return Task.FromResult<IBackupArtifact?>(NoBackup ? null : new Artifact()); }
    public RuntimeRestartIntent CaptureIntent() { Step("capture"); return new(true, "old-profile"); }
    public Task WriteIntentAsync(RuntimeRestartIntent intent) { Step("intent"); return Task.CompletedTask; }
    public Task StopCoreAsync(CancellationToken token) { Step("stop"); return Task.CompletedTask; }
    public Task FlushStateAsync(CancellationToken token) { Step("flush"); return Task.CompletedTask; }
    public Task CloseDatabaseAsync() { Step("close"); return Task.CompletedTask; }
    public void ReplaceConfiguration() => Step("replace");
    public void RequestRestart() => Step("restart");
    public Task DeleteIntentAsync() { Step("delete-intent"); return Task.CompletedTask; }
    public Task RecoverRuntimeAsync(RuntimeRestartIntent intent) { Step("recover"); return Task.CompletedTask; }
    public void DeleteStaging() => Step("staging-cleanup");
    public void DeleteArchive() => Step("archive-cleanup");
    public void Log(string message) { if (CleanupFails) throw new IOException("log"); }
    private sealed class Artifact : IBackupArtifact { public string Name => "safety.zip"; }
    private sealed class Lease(RestoreTestSession owner, CancellationToken token) : IRestoreLease
    {
        public CancellationToken Token => token;
        public ValueTask DisposeAsync() { owner.Step("release"); return ValueTask.CompletedTask; }
    }
}
