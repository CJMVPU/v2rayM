using V2rayM.Application;
using V2rayM.Application.Subscriptions;
using V2rayM.Domain.Subscriptions;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class SubscriptionApplicationTests
{
    [Test]
    public async Task InvalidEditDoesNotTouchRepositoryOrMutationScope()
    {
        var repository = new MemoryRepository();
        var scope = new TrackedScope();
        var service = new SubscriptionService(repository, scope, new Headers());
        var result = await service.SaveAsync(new(" ", ""), "existing");
        await result.Status.Should().BeEqualTo(SubscriptionSaveStatus.NameRequired);
        await repository.Reads.Should().BeEqualTo(0);
        await scope.Entries.Should().BeEqualTo(0);
    }

    [Test]
    public async Task EditPreservesIdentityTimestampAndUneditedSettingsButCanClearOptionalCore()
    {
        var repository = new MemoryRepository();
        var original = Subscription.Apply(new("original", "", Memo: "keep", RequestHeaders: "{}", CustomCoreType: 999), null)
            with { Id = "identity", UpdateTime = 1234 };
        repository.Item = original;
        var scope = new TrackedScope();
        repository.AssertScope = () => { if (!scope.Active) throw new InvalidOperationException("repository outside mutation"); };
        var service = new SubscriptionService(repository, scope, new Headers());
        var result = await service.SaveAsync(new(" renamed ", "", Filter: "", AutoUpdateInterval: -1), "identity");
        await result.Status.Should().BeEqualTo(SubscriptionSaveStatus.Saved);
        await result.Subscription!.Id.Should().BeEqualTo("identity");
        await result.Subscription.UpdateTime.Should().BeEqualTo(1234);
        await result.Subscription.Memo.Should().BeEqualTo("keep");
        await result.Subscription.RequestHeaders.Should().BeEqualTo("{}");
        await result.Subscription.Remarks.Should().BeEqualTo("renamed");
        await result.Subscription.AutoUpdateInterval.Should().BeEqualTo(0);
        await (result.Subscription.CustomCoreType is null).Should().BeTrue();
        await original.CustomCoreType.Should().BeEqualTo(999);
    }

    [Test]
    public async Task SaveRejectionAndMissingIdentityAreNotReportedAsSuccess()
    {
        var repository = new MemoryRepository { Reject = true };
        var service = new SubscriptionService(repository, new RuntimeMutationGate(), new Headers());
        await (await service.SaveAsync(new("new", ""))).Status.Should().BeEqualTo(SubscriptionSaveStatus.Rejected);
        await (await service.SaveAsync(new("missing", ""), "missing")).Status.Should().BeEqualTo(SubscriptionSaveStatus.NotFound);
        await repository.Writes.Should().BeEqualTo(1);
    }

    [Test]
    public async Task QueuedCancellationCannotReadOrWriteRepository()
    {
        var scope = new RuntimeMutationGate();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var blocker = scope.RunAsync(async () => { entered.SetResult(); await release.Task; });
        await entered.Task;
        var repository = new MemoryRepository();
        var service = new SubscriptionService(repository, scope, new Headers());
        using var cancellation = new CancellationTokenSource();
        var pending = service.SaveAsync(new("new", ""), cancellationToken: cancellation.Token);
        cancellation.Cancel();
        var cancelled = false;
        try { await pending; } catch (OperationCanceledException) { cancelled = true; }
        finally { release.SetResult(); await blocker; }
        await cancelled.Should().BeTrue();
        await repository.Reads.Should().BeEqualTo(0);
        await repository.Writes.Should().BeEqualTo(0);
    }

    private sealed class Headers : ISubscriptionHeaders { public bool IsValid(string? value) => true; }
    private sealed class TrackedScope : IMutationScope
    {
        public int Entries; public bool Active;
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken cancellationToken = default)
        { Entries++; Active = true; try { return await action(); } finally { Active = false; } }
    }
    private sealed class MemoryRepository : ISubscriptionRepository
    {
        public Subscription? Item; public int Reads; public int Writes; public bool Reject;
        public Action? AssertScope;
        public Task<IReadOnlyList<Subscription>> ListAsync() => Task.FromResult<IReadOnlyList<Subscription>>(Item is null ? [] : [Item]);
        public Task<Subscription?> FindAsync(string id) { AssertScope?.Invoke(); Reads++; return Task.FromResult(Item?.Id == id ? Item : null); }
        public Task<Subscription?> SaveAsync(Subscription item)
        {
            AssertScope?.Invoke(); Writes++;
            if (Reject) return Task.FromResult<Subscription?>(null);
            Item = item with { Id = string.IsNullOrEmpty(item.Id) ? "assigned" : item.Id };
            return Task.FromResult<Subscription?>(Item);
        }
    }
}
