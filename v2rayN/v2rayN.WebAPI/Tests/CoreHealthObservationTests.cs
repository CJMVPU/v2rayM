using V2rayM.Domain.Runtime;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class CoreHealthObservationTests
{
    private static CoreLifecycleService Runtime(Action<CoreRuntimeSnapshot>? changed = null,
        Func<int, CancellationToken, Task<bool>>? listening = null) => new(
        new(new RuntimeOperationCoordinator()), () => Task.CompletedTask, _ => Task.CompletedTask,
        listening ?? ((_, _) => Task.FromResult(true)), changed ?? (_ => { }), _ => { }, processes => processes);

    private static CoreRuntimeSnapshot Running(string id = "first") => CoreRuntimeSnapshot.Stopped with
        { State = CoreRuntimeState.Running, ProfileId = id, ProxyPort = 10808 };

    [Test]
    public async Task LateStatusFailureCannotReplaceNewCommandOrEmitItsFault()
    {
        var published = new List<CoreRuntimeSnapshot>();
        var runtime = Runtime(published.Add);
        runtime.SetSnapshot(Running());
        var old = runtime.Snapshot;
        foreach (var state in new[] { CoreRuntimeState.Stopping, CoreRuntimeState.Stopped, CoreRuntimeState.Starting, CoreRuntimeState.Running })
        {
            runtime.SetSnapshot(Running("replacement") with { State = state });
            var current = runtime.Snapshot;
            var count = published.Count;
            var observed = runtime.ObserveHealth(old, [], false);
            await observed.PublishedFailure.Should().BeFalse();
            await ReferenceEquals(current, runtime.Snapshot).Should().BeTrue();
            await published.Count.Should().BeEqualTo(count);
        }
    }

    [Test]
    public async Task EqualValuedNewCommandAlsoInvalidatesPriorProbe()
    {
        var runtime = Runtime();
        runtime.SetSnapshot(Running());
        var old = runtime.Snapshot;
        runtime.SetSnapshot(old);
        await runtime.ObserveHealth(old, [], false).PublishedFailure.Should().BeFalse();
        await runtime.Snapshot.State.Should().BeEqualTo(CoreRuntimeState.Running);
    }

    [Test]
    public async Task ConcurrentFailedObserversPublishOneFaultForOneRevision()
    {
        var publications = 0;
        var runtime = Runtime(value => { if (value.State == CoreRuntimeState.Faulted) Interlocked.Increment(ref publications); });
        runtime.SetSnapshot(Running());
        var captured = runtime.Snapshot;
        var results = await Task.WhenAll(Enumerable.Range(0, 32).Select(_ => Task.Run(() => runtime.ObserveHealth(captured, [], false))));
        await results.Count(result => result.PublishedFailure).Should().BeEqualTo(1);
        await publications.Should().BeEqualTo(1);
        await runtime.Snapshot.State.Should().BeEqualTo(CoreRuntimeState.Faulted);
        await runtime.Snapshot.LastFailure.Should().BeEqualTo(CoreLifecycleService.FailureMessage(CoreHealthFailure.ProcessExited));
    }

    [Test]
    public async Task HealthRequiresBothOwnedProcessAndListenerButNeverFaultsCommandTransitions()
    {
        foreach (var state in Enum.GetValues<CoreRuntimeState>())
        foreach (var processes in new[] { false, true })
        foreach (var listener in new[] { false, true })
        {
            var evidence = new CoreHealthEvidence(state, processes, listener);
            await evidence.Running.Should().BeEqualTo(state == CoreRuntimeState.Running && processes && listener);
            if (state != CoreRuntimeState.Running || processes && listener)
                await (evidence.Failure is null).Should().BeTrue();
            else
                await evidence.Failure.Should().BeEqualTo(processes ? CoreHealthFailure.ListenerUnavailable : CoreHealthFailure.ProcessExited);
        }
    }

    [Test]
    public async Task CanceledProbeCannotPublishFailureEvenIfSnapshotStillMatches()
    {
        var runtime = Runtime(); runtime.SetSnapshot(Running());
        var captured = runtime.Snapshot;
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        var cancelled = false;
        try { runtime.ObserveHealth(captured, [], false, cancellation.Token); }
        catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await ReferenceEquals(captured, runtime.Snapshot).Should().BeTrue();
    }

    [Test]
    public async Task DelayedMonitorProbeCannotFaultRestartedCore()
    {
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var runtime = Runtime(listening: (_, _) => { started.TrySetResult(); return release.Task; });
        runtime.SetTrackedProcesses([new(123, "xray", 1, "/isolated/xray")]);
        runtime.SetSnapshot(Running());
        await runtime.StartMonitorAsync();
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromSeconds(3));
            runtime.SetSnapshot(Running("replacement"));
            release.SetResult(false);
            await runtime.StopMonitorAsync();
            await runtime.Snapshot.ProfileId.Should().BeEqualTo("replacement");
            await runtime.Snapshot.State.Should().BeEqualTo(CoreRuntimeState.Running);
        }
        finally { release.TrySetResult(false); await runtime.StopMonitorAsync(); }
    }
}
