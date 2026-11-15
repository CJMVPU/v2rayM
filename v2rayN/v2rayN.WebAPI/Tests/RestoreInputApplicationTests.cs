using V2rayM.Application.Backups;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class RestoreInputApplicationTests
{
    [Test]
    public async Task DownloadReleasesSharedLeaseBeforeExclusiveRestoreAdmission()
    {
        var input = new Input(); input.Release.SetResult();
        await (await new RestoreInputService(input).PrepareAsync(default)).Should().BeTrue();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        await using var restore = await input.Operations.EnterExclusiveAsync(deadline.Token);
        await input.Deleted.Should().BeFalse();
    }

    [Test]
    public async Task ShutdownWaitsForUncancellableDownloadThenDeletesPartialArchive()
    {
        var input = new Input { CleanupFails = true };
        var preparing = new RestoreInputService(input).PrepareAsync(default);
        await input.Started.Task;
        var drain = input.Operations.StopAndDrainAsync(default, TimeSpan.FromSeconds(5));
        await drain.IsCompleted.Should().BeFalse();
        await preparing.IsCompleted.Should().BeFalse();
        input.Release.SetResult();
        var cancelled = false;
        try { await preparing; } catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await input.Deleted.Should().BeTrue();
        await (await drain).Should().BeTrue();
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task FailedReceiveCleansArchiveAndKeepsOriginalException(bool throws)
    {
        var input = new Input { Success = false, Throws = throws, CleanupFails = true }; input.Release.SetResult();
        var failed = false;
        try { failed = !await new RestoreInputService(input).PrepareAsync(default); }
        catch (IOException error) { await error.Message.Should().BeEqualTo("receive"); failed = true; }
        await failed.Should().BeTrue();
        await input.Deleted.Should().BeTrue();
    }

    private sealed class Input : IRestoreInput
    {
        public RuntimeOperationCoordinator Operations = new();
        public TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Success = true, Throws, Deleted, CleanupFails;
        public bool IsStopping => Operations.IsStopping;
        public async ValueTask<IRestoreLease> EnterAsync(CancellationToken token) => new Lease(await Operations.EnterOperationAsync(token));
        public async Task<bool> ReceiveAsync(CancellationToken token)
        { Started.TrySetResult(); await Release.Task; if (Throws) throw new IOException("receive"); return Success; }
        public void DeleteArchive() { Deleted = true; if (CleanupFails) throw new IOException("cleanup"); }
        public void Log(string message) => throw new IOException("log");
        private sealed class Lease(RuntimeOperationCoordinator.Lease lease) : IRestoreLease
        {
            public CancellationToken Token => lease.Token;
            public ValueTask DisposeAsync() => lease.DisposeAsync();
        }
    }
}
