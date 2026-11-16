using V2rayM.Application.Routing;
using V2rayM.Application.Settings;
using V2rayM.Domain.Routing;
using V2rayM.Domain.Runtime;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class RoutingMutationCompensationTests
{
    [Test]
    [Arguments(true)]
    [Arguments(false)]
    public async Task DeleteIsCompensatedWhenFallbackOrLastSelectionSaveFails(bool hasFallback)
    {
        var store = new Store();
        if (hasFallback) store.Items.Add(new("fallback", false));
        var scope = new RuntimeMutationGate();
        var transaction = new SettingsTransaction<Document[], CoreRuntimeState>(new Lifecycle(), scope, store);
        await using var context = await transaction.BeginAsync(() => CoreRuntimeState.Running, state => state, () => true, default);
        var service = new RoutingProfileService(store, scope);
        var failed = false;
        try { await transaction.MutateAsync(context, () => service.DeleteAsync("active"), result => result.Status == RoutingProfileStatus.Saved); }
        catch (InvalidOperationException) { failed = true; }
        await failed.Should().BeTrue();
        await store.Deletes.Should().BeEqualTo(1);
        await store.Restores.Should().BeEqualTo(1);
        await store.Items.Single(item => item.Id == "active").Active.Should().BeTrue();
        await store.Items.Count.Should().BeEqualTo(hasFallback ? 2 : 1);
    }

    [Test]
    public async Task RejectedPartialMutationAlsoRestoresAndRecoveryFailureKeepsBothErrors()
    {
        var store = new Store();
        var transaction = new SettingsTransaction<Document[], CoreRuntimeState>(new Lifecycle(), new RuntimeMutationGate(), store);
        await using var context = await transaction.BeginAsync(() => CoreRuntimeState.Stopped, state => state, () => false, default);
        var success = await transaction.MutateAsync(context, () => { store.Items.Clear(); return Task.FromResult(false); }, value => value);
        await success.Should().BeFalse();
        await store.Items.Count.Should().BeEqualTo(1);
        store.FailRecovery = true;
        AggregateException? error = null;
        try { await transaction.MutateAsync<bool>(context, () => throw new InvalidOperationException("mutation"), value => value); }
        catch (AggregateException caught) { error = caught; }
        await error!.InnerExceptions.Count.Should().BeEqualTo(2);
        await error.InnerExceptions[0].Message.Should().BeEqualTo("mutation");
        await error.InnerExceptions[1].Message.Should().BeEqualTo("recovery");
    }

    private sealed record Document(string Id, bool Active) : IRoutingProfileDocument
    {
        public int Sort => 1;
        public RoutingProfileSettings Settings => new("test", null, true, false, null, null, "[]");
        public void Initialize(int sort) => throw new NotSupportedException();
        public void Edit(RoutingProfileSettings settings) => throw new NotSupportedException();
    }
    private sealed class Store : IRoutingProfileStore, ISettingsSnapshotStore<Document[]>
    {
        public List<Document> Items = [new("active", true)];
        public int Deletes, Restores;
        public bool FailRecovery;
        public Task<Document[]> CaptureAsync() => Task.FromResult(Items.ToArray());
        public Task RestoreAsync(Document[] snapshot)
        { if (FailRecovery) throw new InvalidOperationException("recovery"); Items = snapshot.ToList(); Restores++; return Task.CompletedTask; }
        public Task RecoverPendingRestoreAsync() => Task.CompletedTask;
        public Task<IReadOnlyList<IRoutingProfileDocument>> ListAsync() => Task.FromResult<IReadOnlyList<IRoutingProfileDocument>>(Items.ToArray());
        public Task<IRoutingProfileDocument?> FindAsync(string id) => Task.FromResult<IRoutingProfileDocument?>(Items.Find(item => item.Id == id));
        public Task DeleteAsync(IRoutingProfileDocument document) { Items.Remove((Document)document); Deletes++; return Task.CompletedTask; }
        public Task<bool> ActivateAsync(IRoutingProfileDocument document) => Task.FromResult(false);
        public Task ClearSelectionAsync() => throw new InvalidOperationException("selection save");
        public Task<bool> SaveAsync(IRoutingProfileDocument document) => throw new NotSupportedException();
        public Task<bool> ImportPresetsAsync() => throw new NotSupportedException();
    }
    private sealed class Lifecycle : IExclusiveScope, IAsyncDisposable
    {
        public Task<IAsyncDisposable> EnterAsync(CancellationToken token) => Task.FromResult<IAsyncDisposable>(this);
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
