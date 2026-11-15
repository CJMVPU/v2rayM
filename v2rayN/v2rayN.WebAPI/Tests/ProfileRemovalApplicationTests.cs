using V2rayM.Application;
using V2rayM.Application.Profiles;

namespace v2rayN.WebAPI.Tests;

public class ProfileRemovalApplicationTests
{
    [Test]
    public async Task StopFailureNeverDeletesOrRestarts()
    {
        var scope = new Scope(); var repository = new Repository(scope); var events = new Events();
        var service = new ProfileRemovalService(repository, scope, events);
        var result = await service.DeleteAsync(["running"], () => Task.FromResult(false), () => throw new InvalidOperationException());
        await result.Status.Should().BeEqualTo(ProfileRemovalStatus.StopFailed);
        await repository.Deleted.Should().BeFalse();
        await events.Changes.Should().BeEqualTo(0);
    }

    [Test]
    public async Task RestartOccursOutsideMutationAndFailureReportsCommittedDeletion()
    {
        var scope = new Scope(); var repository = new Repository(scope); var events = new Events();
        var service = new ProfileRemovalService(repository, scope, events);
        var result = await service.DeleteAsync(["running"], () => Task.FromResult(true), () =>
        { if (scope.Active || !repository.Deleted) throw new InvalidOperationException("restart ordering"); return Task.FromResult(false); });
        await result.Status.Should().BeEqualTo(ProfileRemovalStatus.RestartFailed);
        await result.Count.Should().BeEqualTo(1);
        await repository.Deleted.Should().BeTrue();
        await events.Changes.Should().BeEqualTo(1);
    }

    [Test]
    public async Task FaultedButOwnedProcessMustStopWithoutAutomaticRestart()
    {
        var scope = new Scope(); var repository = new Repository(scope) { WasRunning = false, Active = true }; var events = new Events();
        var stopped = false;
        var result = await new ProfileRemovalService(repository, scope, events).DeleteAsync(["running"],
            () => { stopped = true; return Task.FromResult(true); }, () => throw new InvalidOperationException());
        await stopped.Should().BeTrue();
        await result.Status.Should().BeEqualTo(ProfileRemovalStatus.Deleted);
        await result.Restarted.Should().BeFalse();
    }

    [Test]
    public async Task MissingRequestedRunningIdentityDoesNotStopAnUnrelatedCore()
    {
        var scope = new Scope(); var repository = new Repository(scope) { Existing = ["other"] }; var events = new Events();
        var result = await new ProfileRemovalService(repository, scope, events).DeleteAsync(["running", "other"],
            () => throw new InvalidOperationException(), () => throw new InvalidOperationException());
        await result.Count.Should().BeEqualTo(1);
        await repository.Reset.Should().BeFalse();
    }

    private sealed class Scope : IMutationScope
    {
        public bool Active;
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        { Active = true; try { return await action(); } finally { Active = false; } }
    }
    private sealed class Repository(Scope scope) : IProfileRemovalRepository
    {
        public bool WasRunning = true; public bool Active = true; public bool Deleted; public bool Reset;
        public IReadOnlyList<string> Existing = ["running"];
        public string SelectedGroup => "group";
        public Task<ProfileRemovalPlan> PlanAsync(IReadOnlyList<string> ids)
        { if (!scope.Active) throw new InvalidOperationException(); return Task.FromResult(new ProfileRemovalPlan(Existing, "running", "running", WasRunning, Active)); }
        public Task<string?> DeleteAsync(IReadOnlyList<string> ids, bool resetSelection)
        { if (!scope.Active) throw new InvalidOperationException(); Deleted = true; Reset = resetSelection; return Task.FromResult<string?>("next"); }
    }
    private sealed class Events : IProfileCatalogEvents
    {
        public int Changes;
        public void Changed(string group) => Changes++;
        public void Imported(int count) { }
    }
}
