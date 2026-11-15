using V2rayM.Application;
using V2rayM.Application.Profiles;
using V2rayM.Domain.Profiles;

namespace v2rayN.WebAPI.Tests;

public class ProfileEditorApplicationTests
{
    [Test]
    public async Task UnsupportedProfileCannotReadOrWriteRepository()
    {
        var scope = new Scope(); var repo = new Repository(scope); var edit = new Edit(scope) { Supported = false };
        var result = await new ProfileEditorService(repo, scope, new Events()).SaveAsync(edit, "node", () => throw new InvalidOperationException());
        await result.Validation.Should().BeEqualTo(ProfileValidation.Unsupported);
        await scope.Entries.Should().BeEqualTo(0);
        await edit.Persisted.Should().BeFalse();
    }

    [Test]
    public async Task ChangingProtocolCannotBindOrPersistExistingNode()
    {
        var scope = new Scope(); var repo = new Repository(scope) { Protocol = 2 }; var edit = new Edit(scope);
        var result = await new ProfileEditorService(repo, scope, new Events()).SaveAsync(edit, "node", () => throw new InvalidOperationException());
        await result.Status.Should().BeEqualTo(ProfileSaveStatus.ImmutableProtocol);
        await edit.Persisted.Should().BeFalse();
        await (edit.Bound is null).Should().BeTrue();
    }

    [Test]
    public async Task EditUsesStoredMembershipAndRestartFailureDoesNotUndoSuccessfulSave()
    {
        var scope = new Scope(); var repo = new Repository(scope); var edit = new Edit(scope); var events = new Events();
        var result = await new ProfileEditorService(repo, scope, events).SaveAsync(edit, "node", () =>
        { if (scope.Active || !edit.Persisted) throw new InvalidOperationException("restart before commit"); return Task.FromResult(false); });
        await result.Status.Should().BeEqualTo(ProfileSaveStatus.RestartFailed);
        await edit.Bound!.GroupId.Should().BeEqualTo("original-group");
        await edit.Bound.FromSubscription.Should().BeTrue();
        await result.Id.Should().BeEqualTo("node");
        await events.Changes.Should().BeEqualTo(1);
    }

    [Test]
    public async Task GroupCycleNeverPersistsOrRestarts()
    {
        var scope = new Scope(); var repo = new Repository(scope); var edit = new Edit(scope) { Kind = ProfileKind.Group, Cycle = true };
        var result = await new ProfileEditorService(repo, scope, new Events()).SaveAsync(edit, "node", () => throw new InvalidOperationException());
        await result.Status.Should().BeEqualTo(ProfileSaveStatus.InvalidChildren);
        await edit.Persisted.Should().BeFalse();
    }

    [Test]
    public async Task PersistenceExceptionCannotPublishOrRestart()
    {
        var scope = new Scope(); var repo = new Repository(scope); var edit = new Edit(scope) { Throw = true }; var events = new Events();
        var result = await new ProfileEditorService(repo, scope, events).SaveAsync(edit, "node", () => throw new InvalidOperationException());
        await result.Status.Should().BeEqualTo(ProfileSaveStatus.PersistenceFailed);
        await (result.Error is InvalidOperationException).Should().BeTrue();
        await events.Changes.Should().BeEqualTo(0);
    }

    private sealed class Scope : IMutationScope
    {
        public bool Active; public int Entries;
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        { Active = true; Entries++; try { return await action(); } finally { Active = false; } }
    }
    private sealed class Repository(Scope scope) : IProfileEditorRepository
    {
        public int Protocol = 1;
        private void Check() { if (!scope.Active) throw new InvalidOperationException("outside scope"); }
        public string SelectedGroup => "selected-group";
        public Task<ProfileIdentity?> FindAsync(string id) { Check(); return Task.FromResult<ProfileIdentity?>(new(id, Protocol, "original-group", true)); }
        public Task<bool> GroupExistsAsync(string id) { Check(); return Task.FromResult(true); }
        public Task<int> CountChildrenAsync(IReadOnlyList<string> ids) { Check(); return Task.FromResult(ids.Count); }
        public bool IsRunning(string id) { Check(); return true; }
    }
    private sealed class Edit(Scope scope) : IProfileEditSession
    {
        public bool Supported = true; public bool Persisted; public bool Cycle; public bool Throw; public ProfileIdentity? Bound;
        public ProfileKind Kind = ProfileKind.Simple;
        public ProfileEditFacts Facts => new(1, Kind, Supported, "name", "host", 443, "secret", true, false, null, true, true, ["child"], null);
        public string Id => Bound?.Id ?? "";
        public void Bind(ProfileIdentity identity) { if (!scope.Active) throw new InvalidOperationException(); Bound = identity; }
        public Task<bool> HasCycleAsync() => Task.FromResult(Cycle);
        public Task<int> PersistAsync(bool isNew)
        { if (!scope.Active || Throw) throw new InvalidOperationException(); Persisted = true; return Task.FromResult(0); }
    }
    private sealed class Events : IProfileCatalogEvents
    {
        public int Changes;
        public void Changed(string group) => Changes++;
        public void Imported(int count) { }
    }
}
