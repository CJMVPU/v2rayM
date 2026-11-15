using V2rayM.Application;
using V2rayM.Application.Backups;
using V2rayM.Domain.Backups;

namespace v2rayN.WebAPI.Tests;

public class BackupArchiveApplicationTests
{
    [Test]
    public async Task FlushAndSnapshotShareWriteScopeButCompressionDoesNotBlockWriters()
    {
        var scope = new Scope(); var session = new Session(scope);
        var result = await new BackupArchiveService(scope).CreateAsync(session);
        await result.Status.Should().BeEqualTo(BackupArchiveStatus.Created);
        await session.Actions.SequenceEqual(["flush", "capture", "compress", "snapshot-cleanup"]).Should().BeTrue();
        await result.Artifact!.Name.Should().BeEqualTo("backup.zip");
    }

    [Test]
    [Arguments("flush")]
    [Arguments("capture")]
    [Arguments("compress")]
    public async Task AnyFailureRemovesPartialArchiveAndSnapshotEvenWhenCleanupAndLogFail(string fail)
    {
        var scope = new Scope(); var session = new Session(scope) { Fail = fail, CleanupFails = true };
        var result = await new BackupArchiveService(scope).CreateAsync(session);
        await result.Status.Should().BeEqualTo(BackupArchiveStatus.Failed);
        await session.Actions.TakeLast(2).SequenceEqual(["archive-cleanup", "snapshot-cleanup"]).Should().BeTrue();
        await scope.Active.Should().BeFalse();
    }

    [Test]
    [Arguments(0L, BackupArchiveStatus.Failed)]
    [Arguments(BackupPolicy.MaximumArchiveBytes, BackupArchiveStatus.Created)]
    [Arguments(BackupPolicy.MaximumArchiveBytes + 1, BackupArchiveStatus.TooLarge)]
    public async Task OnlyNonemptyArchiveWithinLimitTransfersOwnership(long size, BackupArchiveStatus expected)
    {
        var scope = new Scope(); var session = new Session(scope) { ArchiveSize = size };
        var result = await new BackupArchiveService(scope).CreateAsync(session);
        await result.Status.Should().BeEqualTo(expected);
        await session.Actions.Contains("archive-cleanup").Should().BeEqualTo(expected != BackupArchiveStatus.Created);
    }

    [Test]
    public async Task FailedCompressorReturnAlsoDeletesPartialOutput()
    {
        var scope = new Scope(); var session = new Session(scope) { Created = false };
        await (await new BackupArchiveService(scope).CreateAsync(session)).Status.Should().BeEqualTo(BackupArchiveStatus.Failed);
        await session.Actions.Contains("archive-cleanup").Should().BeTrue();
    }

    [Test]
    public async Task CleanupFailureCannotRevokeCompletedBackup()
    {
        var scope = new Scope(); var session = new Session(scope) { CleanupFails = true };
        await (await new BackupArchiveService(scope).CreateAsync(session)).Status.Should().BeEqualTo(BackupArchiveStatus.Created);
        await session.Actions.Contains("archive-cleanup").Should().BeFalse();
    }
    private sealed class Scope : IMutationScope
    {
        public bool Active;
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        { Active = true; try { return await action(); } finally { Active = false; } }
    }
    private sealed class Session(Scope scope) : IBackupArchiveSession
    {
        public List<string> Actions = [];
        public string? Fail;
        public bool Created = true, CleanupFails;
        public long ArchiveSize { get; set; } = 42;
        public IBackupArtifact Artifact => new ArtifactValue();
        private void Step(string phase, bool inScope = false)
        {
            if (scope.Active != inScope) throw new InvalidOperationException("Wrong mutation boundary");
            Actions.Add(phase); if (phase == Fail) throw new IOException(phase);
        }
        public Task FlushAsync() { Step("flush", true); return Task.CompletedTask; }
        public Task CaptureAsync() { Step("capture", true); return Task.CompletedTask; }
        public bool CreateArchive() { Step("compress"); return Created; }
        public void DeleteArchive() { Step("archive-cleanup"); if (CleanupFails) throw new IOException("cleanup"); }
        public void DeleteSnapshot() { Step("snapshot-cleanup"); if (CleanupFails) throw new IOException("cleanup"); }
        public void Log(string message) => throw new IOException("log");
        private sealed class ArtifactValue : IBackupArtifact { public string Name => "backup.zip"; }
    }
}
