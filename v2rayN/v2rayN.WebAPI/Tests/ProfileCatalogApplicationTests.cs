using V2rayM.Application;
using V2rayM.Application.Profiles;
using V2rayM.Domain.Profiles;

namespace v2rayN.WebAPI.Tests;

public class ProfileCatalogApplicationTests
{
    [Test]
    public async Task MissingImportGroupDoesNotWriteOrPublish()
    {
        var scope = new Scope(); var store = new Catalog(scope) { GroupExists = false }; var events = new Events();
        var service = new ProfileCatalogService(store, scope, events);
        var result = await service.ImportAsync("node", "missing", false);
        await result.Status.Should().BeEqualTo(ProfileCatalogStatus.GroupNotFound);
        await store.Writes.Should().BeEqualTo(0);
        await events.Changes.Should().BeEqualTo(0);
    }

    [Test]
    public async Task ImportPersistsBeforePublishingAndReadsSelectionUnderLock()
    {
        var scope = new Scope(); var store = new Catalog(scope); var events = new Events();
        events.OnChange = () => { if (!store.Saved) throw new InvalidOperationException("published before save"); };
        var service = new ProfileCatalogService(store, scope, events);
        var result = await service.ImportAsync("node", null, false);
        await result.Status.Should().BeEqualTo(ProfileCatalogStatus.Completed);
        await result.GroupId.Should().BeEqualTo("group");
        await result.Count.Should().BeEqualTo(2);
        await events.Changes.Should().BeEqualTo(1);
    }

    [Test]
    public async Task CopyFiltersEmptyAndDuplicateIdsPreservingRequestedOrder()
    {
        var scope = new Scope(); var store = new Catalog(scope); var events = new Events();
        var service = new ProfileCatalogService(store, scope, events);
        var result = await service.CopyAsync(["b", "", "a", "b", " "]);
        await string.Join(",", store.Copied).Should().BeEqualTo("b,a");
        await result.Count.Should().BeEqualTo(2);
    }

    [Test]
    public async Task MoveToMissingGroupDoesNotReadOrChangeProfiles()
    {
        var scope = new Scope(); var store = new Catalog(scope) { GroupExists = false }; var events = new Events();
        var service = new ProfileCatalogService(store, scope, events);
        var result = await service.MoveToGroupAsync(["a"], "missing");
        await result.Status.Should().BeEqualTo(ProfileCatalogStatus.GroupNotFound);
        await store.ProfileReads.Should().BeEqualTo(0);
        await store.Writes.Should().BeEqualTo(0);
    }

    [Test]
    public async Task ReorderUsesCurrentOrderedIdsAndRejectsAbsentNode()
    {
        var scope = new Scope(); var store = new Catalog(scope); var events = new Events();
        var service = new ProfileCatalogService(store, scope, events);
        await (await service.ReorderAsync("missing", ProfileMove.Up, -1)).Status.Should().BeEqualTo(ProfileCatalogStatus.NotInGroup);
        await store.Writes.Should().BeEqualTo(0);
        await (await service.ReorderAsync("a", ProfileMove.Up, -1)).Status.Should().BeEqualTo(ProfileCatalogStatus.Completed);
        await store.ReorderedIndex.Should().BeEqualTo(1);
    }

    [Test]
    public async Task UndefinedSortColumnCannotReachPersistence()
    {
        var scope = new Scope(); var store = new Catalog(scope); var events = new Events();
        var service = new ProfileCatalogService(store, scope, events);
        foreach (var column in new[] { "999", "unknown", "-1" })
            await (await service.SortAsync(null, column, true)).Status.Should().BeEqualTo(ProfileCatalogStatus.SortColumnInvalid);
        await scope.Entries.Should().BeEqualTo(0);
        await store.Writes.Should().BeEqualTo(0);
    }

    private sealed class Scope : IMutationScope
    {
        public bool Active; public int Entries;
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        { Active = true; Entries++; try { return await action(); } finally { Active = false; } }
    }
    private sealed class Events : IProfileCatalogEvents
    {
        public int Changes; public Action? OnChange;
        public void Changed(string id) { OnChange?.Invoke(); Changes++; }
        public void Imported(int count) { }
    }
    private sealed class Catalog(Scope scope) : IProfileCatalog
    {
        public bool GroupExists = true; public int Writes; public int ProfileReads; public bool Saved;
        public IReadOnlyList<string> Copied = []; public int ReorderedIndex = -1;
        private void Check() { if (!scope.Active) throw new InvalidOperationException("outside mutation scope"); }
        public string SelectedGroup { get { Check(); return "group"; } }
        public Task<bool> GroupExistsAsync(string id) { Check(); return Task.FromResult(GroupExists); }
        public Task SelectGroupAsync(string id) { Check(); Writes++; return Task.CompletedTask; }
        public Task<int> ImportAsync(string content, string group, bool subscription) { Check(); Writes++; return Task.FromResult(2); }
        public Task SaveConfigurationAsync() { Check(); Saved = true; return Task.CompletedTask; }
        public Task<IReadOnlyList<string>> FindIdsAsync(IReadOnlyList<string> ids, bool ordered) { Check(); ProfileReads++; return Task.FromResult(ids); }
        public Task<bool> CopyAsync(IReadOnlyList<string> ids) { Check(); Writes++; Copied = ids; return Task.FromResult(true); }
        public Task<bool> MoveToGroupAsync(IReadOnlyList<string> ids, string group) { Check(); Writes++; return Task.FromResult(true); }
        public Task<IReadOnlyList<string>> OrderedIdsAsync(string group) { Check(); return Task.FromResult<IReadOnlyList<string>>(["b", "a"]); }
        public Task<bool> ReorderAsync(IReadOnlyList<string> ids, int index, ProfileMove direction, int position) { Check(); Writes++; ReorderedIndex = index; return Task.FromResult(true); }
        public Task<bool> SortAsync(string group, ProfileSortField column, bool ascending) { Check(); Writes++; return Task.FromResult(true); }
    }
}
