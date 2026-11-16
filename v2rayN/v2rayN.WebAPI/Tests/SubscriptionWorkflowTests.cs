using V2rayM.Application.Subscriptions;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class SubscriptionWorkflowTests
{
    [Test]
    public async Task PartialSuccessStampsOnlySuccessfulIdsAndBackoffDoesNotChangeSuccessTime()
    {
        var clock = new Clock();
        var updater = new Updater { Outcomes = [new("ok", SubscriptionUpdateStatus.Succeeded),
            new("failed", SubscriptionUpdateStatus.Failed), new("disabled", SubscriptionUpdateStatus.Skipped)] };
        updater.Release.SetResult();
        var events = new Events();
        var service = new SubscriptionUpdateService(new RuntimeOperationCoordinator(), new RuntimeMutationGate(), updater, events, clock);
        await service.TryStart("", false, default)!;
        await string.Join(",", updater.StampedIds).Should().BeEqualTo("ok");
        await events.Changes.Should().BeEqualTo(1);
        await service.CanAutoUpdate("failed").Should().BeFalse();
        await service.CanAutoUpdate("ok").Should().BeTrue();
        // A normal Task return with a failed result is not an update success.
        updater.Outcomes = [new("failed", SubscriptionUpdateStatus.Failed)];
        await service.TryStart("failed", false, default)!; // manual retry is allowed
        await updater.Stamps.Should().BeEqualTo(1);
        await updater.Saves.Should().BeEqualTo(1);
        await events.Changes.Should().BeEqualTo(1);
        clock.Now = clock.Now.AddMinutes(5);
        await service.CanAutoUpdate("failed").Should().BeTrue();
    }

    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = DateTimeOffset.Parse("2026-11-16T00:00:00Z");
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Test]
    public async Task UpdateAllConflictsWithEveryIndividualAndFailureReleasesAdmission()
    {
        var operations = new RuntimeOperationCoordinator();
        var updater = new Updater { Throw = true };
        var events = new Events();
        var service = new SubscriptionUpdateService(operations, new RuntimeMutationGate(), updater, events, TimeProvider.System);
        var task = service.TryStart("one", true, default)!;
        await updater.Entered.Task;
        await (service.TryStart("one", true, default) is null).Should().BeTrue();
        await (service.TryStart("", true, default) is null).Should().BeTrue();
        updater.Release.SetResult();
        await task;
        await events.Failures.Should().BeEqualTo(1);
        await service.Running().Count.Should().BeEqualTo(0);
        await updater.Saves.Should().BeEqualTo(0);
        updater.Throw = false;
        await service.TryStart("", false, default)!;
        await updater.Saves.Should().BeEqualTo(1);
        await events.Changes.Should().BeEqualTo(1);
    }

    [Test]
    public async Task ShutdownWaitsForUpstreamCompletionWithoutStampingCancelledWork()
    {
        var operations = new RuntimeOperationCoordinator();
        var updater = new Updater();
        var events = new Events();
        var service = new SubscriptionUpdateService(operations, new RuntimeMutationGate(), updater, events, TimeProvider.System);
        var task = service.TryStart("one", false, default)!;
        await updater.Entered.Task;
        var drain = operations.StopAndDrainAsync(default, TimeSpan.FromSeconds(5));
        await drain.IsCompleted.Should().BeFalse();
        await (service.TryStart("two", false, default) is null).Should().BeTrue();
        updater.Release.SetResult();
        await task;
        await (await drain).Should().BeTrue();
        await updater.Saves.Should().BeEqualTo(0);
        await updater.Stamps.Should().BeEqualTo(0);
        await events.Changes.Should().BeEqualTo(0);
        await events.Failures.Should().BeEqualTo(0);
    }

    [Test]
    public async Task ShutdownAdmissionStopsMetadataBeforeLinkedTokenCallbacksArrive()
    {
        var operations = new DelayedCancellation();
        var updater = new Updater();
        var events = new Events();
        var service = new SubscriptionUpdateService(operations, new RuntimeMutationGate(), updater, events, TimeProvider.System);
        var task = service.TryStart("one", false, default)!;
        await updater.Entered.Task;
        operations.IsStopping = true;
        updater.Release.SetResult();
        await task;
        await updater.Saves.Should().BeEqualTo(0);
        await updater.Stamps.Should().BeEqualTo(0);
        await events.Changes.Should().BeEqualTo(0);
        await events.Failures.Should().BeEqualTo(0);
    }
    private sealed class DelayedCancellation : V2rayM.Application.IOperationScope
    {
        public bool IsStopping { get; set; }
        public CancellationToken ShutdownToken => CancellationToken.None;
        public Task RunAsync(Func<CancellationToken, Task> operation, CancellationToken token) => operation(token);
    }

    [Test]
    public async Task ConfigurationFailureNeverStampsOrPublishesCompletion()
    {
        var updater = new Updater { SaveThrows = true };
        updater.Release.SetResult();
        var events = new Events();
        var service = new SubscriptionUpdateService(new RuntimeOperationCoordinator(), new RuntimeMutationGate(), updater, events, TimeProvider.System);
        await service.TryStart("one", false, default)!;
        await updater.Stamps.Should().BeEqualTo(0);
        await events.Changes.Should().BeEqualTo(0);
        await events.Failures.Should().BeEqualTo(1);
    }

    [Test]
    public async Task StopFailurePreservesSubscriptionAndSelectedProfile()
    {
        var repository = new Removal { Plan = new(true, true, false) };
        var service = new SubscriptionRemovalService(repository, new RuntimeMutationGate());
        var result = await service.DeleteAsync("one", () => Task.FromResult(false));
        await result.Should().BeEqualTo(SubscriptionRemovalResult.StopFailed);
        await repository.Deleted.Should().BeFalse();
    }

    [Test]
    public async Task RunningProfileIsProtectedEvenWhenSelectionDiffers()
    {
        var repository = new Removal { Plan = new(true, false, true) };
        var stopped = false;
        var service = new SubscriptionRemovalService(repository, new RuntimeMutationGate());
        var result = await service.DeleteAsync("one", () => { stopped = true; return Task.FromResult(true); });
        await result.Should().BeEqualTo(SubscriptionRemovalResult.Deleted);
        await stopped.Should().BeTrue();
        await repository.Deleted.Should().BeTrue();
        await repository.Reset.Should().BeFalse();
    }

    [Test]
    public async Task MissingSubscriptionCannotStopCoreOrDeleteData()
    {
        var repository = new Removal { Plan = new(false, false, false) };
        var service = new SubscriptionRemovalService(repository, new RuntimeMutationGate());
        var result = await service.DeleteAsync("missing", () => throw new InvalidOperationException());
        await result.Should().BeEqualTo(SubscriptionRemovalResult.NotFound);
        await repository.Deleted.Should().BeFalse();
    }

    private sealed class Removal : ISubscriptionRemovalRepository
    {
        public SubscriptionRemovalPlan Plan = new(false, false, false);
        public bool Deleted; public bool Reset;
        public Task<SubscriptionRemovalPlan> PlanAsync(string id) => Task.FromResult(Plan);
        public Task DeleteAsync(string id, bool resetSelection) { Deleted = true; Reset = resetSelection; return Task.CompletedTask; }
    }
    private sealed class Updater : ISubscriptionUpdater
    {
        public TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Throw; public bool SaveThrows; public int Saves; public int Stamps;
        public IReadOnlyList<SubscriptionUpdateResult>? Outcomes;
        public List<string> StampedIds = [];
        public async Task<IReadOnlyList<SubscriptionUpdateResult>> UpdateAsync(string id, bool useProxy, Func<bool, string, Task> progress)
        { Entered.TrySetResult(); await Release.Task; if (Throw) throw new InvalidOperationException("injected"); return Outcomes ?? [new(id, SubscriptionUpdateStatus.Succeeded)]; }
        public Task SaveConfigurationAsync() { Saves++; if (SaveThrows) throw new InvalidOperationException("save"); return Task.CompletedTask; }
        public Task StampAsync(string id, long unixTime) { Stamps++; StampedIds.Add(id); return Task.CompletedTask; }
    }
    private sealed class Events : ISubscriptionUpdateEvents
    {
        public int Changes; public int Failures;
        public Task ProgressAsync(string id, bool success, string message) => Task.CompletedTask;
        public void Changed(string id) => Changes++;
        public void Failed(Exception exception) => Failures++;
    }
}
