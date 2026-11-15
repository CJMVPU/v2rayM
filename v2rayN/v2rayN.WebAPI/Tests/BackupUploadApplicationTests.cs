using V2rayM.Application.Backups;

namespace v2rayN.WebAPI.Tests;

public class BackupUploadApplicationTests
{
    [Test]
    [Arguments(true, false, BackupUploadStatus.Uploaded)]
    [Arguments(false, false, BackupUploadStatus.UploadFailed)]
    [Arguments(false, true, BackupUploadStatus.UploadFailed)]
    public async Task TransferAlwaysReleasesLocalArchiveAndCleanupCannotMaskOutcome(bool success, bool throws, BackupUploadStatus expected)
    {
        var remote = new Remote { Success = success, Throws = throws };
        var result = await new BackupUploadService(remote).UploadAsync();
        await result.Status.Should().BeEqualTo(expected);
        await remote.Deleted.Should().BeTrue();
    }
    [Test]
    public async Task FailedCreationNeverStartsNetworkTransfer()
    {
        var remote = new Remote { Created = false };
        var result = await new BackupUploadService(remote).UploadAsync();
        await result.Status.Should().BeEqualTo(BackupUploadStatus.CreationFailed);
        await result.CreationStatus.Should().BeEqualTo(BackupArchiveStatus.TooLarge);
        await remote.Uploaded.Should().BeFalse();
        await remote.Deleted.Should().BeFalse();
    }
    private sealed class Remote : IBackupUpload
    {
        public bool Success, Throws, Deleted, Uploaded, Created = true;
        public Task<BackupArchiveResult> CreateAsync() => Task.FromResult(Created
            ? new BackupArchiveResult(BackupArchiveStatus.Created, new Artifact()) : new(BackupArchiveStatus.TooLarge));
        public Task<bool> UploadAsync(IBackupArtifact artifact)
        { Uploaded = true; if (Throws) throw new IOException("network failed"); return Task.FromResult(Success); }
        public void DeleteLocal(IBackupArtifact artifact) { Deleted = true; throw new IOException("cleanup failed"); }
        public void Log(string message) => throw new IOException("log failed");
        private sealed class Artifact : IBackupArtifact { public string Name => "backup.zip"; }
    }
}
