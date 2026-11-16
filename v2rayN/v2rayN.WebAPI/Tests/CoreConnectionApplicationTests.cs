using V2rayM.Application.Runtime;
using V2rayM.Domain.Runtime;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class CoreConnectionApplicationTests
{
    [Test]
    [Arguments(CoreRuntimeState.Stopped, false)]
    [Arguments(CoreRuntimeState.Starting, false)]
    [Arguments(CoreRuntimeState.Running, true)]
    [Arguments(CoreRuntimeState.Stopping, false)]
    [Arguments(CoreRuntimeState.Restarting, false)]
    [Arguments(CoreRuntimeState.Faulted, true)]
    public async Task RestartAdmissionRequiresRecoverableStateAndRememberedProfile(CoreRuntimeState state, bool allowed)
    {
        var runtime = new CoreConnectionTestRuntime { Current = new(state, "profile-1", []) };
        var result = await new CoreConnectionService(runtime).RestartAsync(default);
        await result.Status.Should().BeEqualTo(allowed ? CoreConnectionStatus.Restarted : CoreConnectionStatus.NotRunning);
        runtime.Current = new(state, null, [7]);
        runtime.Calls.Clear();
        await (await new CoreConnectionService(runtime).RestartAsync(default)).Status.Should().BeEqualTo(CoreConnectionStatus.NotRunning);
        await runtime.Calls.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task SameProfileIsIdempotentButExplicitSelectionRevalidatesAndReconnects()
    {
        var runtime = new CoreConnectionTestRuntime();
        var service = new CoreConnectionService(runtime);
        await (await service.StartAsync("profile-1", default)).Status.Should().BeEqualTo(CoreConnectionStatus.AlreadyRunning);
        await string.Join(",", runtime.Calls).Should().BeEqualTo("resolve");
        runtime.Calls.Clear();
        await (await service.StartAsync("profile-1", default, selectProfile: true)).Status.Should().BeEqualTo(CoreConnectionStatus.Started);
        await string.Join(",", runtime.Calls).Should().BeEqualTo("resolve,reset-cache,prepare,select,stop-monitor,stop,launch,listen,start-monitor,publish");
    }

    [Test]
    public async Task FirstStartRecomputesConfigurationCacheBeforePreparingPorts()
    {
        var runtime = new CoreConnectionTestRuntime { Current = new(CoreRuntimeState.Stopped, null, []) };
        var result = await new CoreConnectionService(runtime).StartAsync("profile-1", default);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.Started);
        await (runtime.Calls.IndexOf("reset-cache") < runtime.Calls.IndexOf("prepare")).Should().BeTrue();
        await runtime.Calls.Count(value => value == "reset-cache").Should().BeEqualTo(1);
    }

    [Test]
    public async Task RejectedSelectionKeepsTheServingCoreAndSavedSelection()
    {
        var runtime = new CoreConnectionTestRuntime { RejectPreflight = true };
        var previous = runtime.Current;
        var result = await new CoreConnectionService(runtime).StartAsync("new-profile", default, selectProfile: true);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.PreflightRejected);
        await runtime.Current.Should().BeEqualTo(previous);
        await string.Join(",", runtime.Calls).Should().BeEqualTo("resolve,reset-cache,prepare");
    }

    [Test]
    public async Task ThrownRestartPreflightKeepsServingProcessAndIdentity()
    {
        var runtime = new CoreConnectionTestRuntime { ThrowPreflight = true };
        var previous = runtime.Current;
        var result = await new CoreConnectionService(runtime).RestartAsync(default);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.RestartFailed);
        await result.Stage.Should().BeEqualTo("preflight");
        await runtime.Current.Should().BeEqualTo(previous);
        await runtime.Calls.Contains("stop").Should().BeFalse();
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task StopFailureNeverLaunchesAnotherCore(bool restart)
    {
        var runtime = new CoreConnectionTestRuntime { FailStop = true };
        var service = new CoreConnectionService(runtime);
        var result = restart ? await service.RestartAsync(default) : await service.StartAsync("new-profile", default);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.StopFailed);
        await runtime.Current.State.Should().BeEqualTo(CoreRuntimeState.Faulted);
        await runtime.Calls.Contains("launch").Should().BeFalse();
        await result.ProcessIds!.Single().Should().BeEqualTo(7);
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task ReadinessRequiresBothListenerAndOwnedChildAndCleansUp(bool listenerMissing)
    {
        var runtime = new CoreConnectionTestRuntime
        { Current = new(CoreRuntimeState.Stopped, null, []), ListenerReady = !listenerMissing, OwnChildAfterLaunch = listenerMissing };
        var result = await new CoreConnectionService(runtime).StartAsync("profile-1", default);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.StartFailed);
        await runtime.Current.State.Should().BeEqualTo(CoreRuntimeState.Faulted);
        await runtime.Current.ProcessIds.Count.Should().BeEqualTo(0);
        await runtime.CleanupTokenCanBeCanceled.Should().BeFalse();
        await runtime.Calls.Contains("start-monitor").Should().BeFalse();
    }

    [Test]
    public async Task CancellationDuringLaunchStillCompletesUncancelledCleanup()
    {
        using var cancel = new CancellationTokenSource();
        var runtime = new CoreConnectionTestRuntime { Current = new(CoreRuntimeState.Stopped, null, []), CancelDuringWait = cancel };
        var result = await new CoreConnectionService(runtime).StartAsync("profile-1", cancel.Token);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.StartFailed);
        await cancel.IsCancellationRequested.Should().BeTrue();
        await runtime.CleanupTokenCanBeCanceled.Should().BeFalse();
        await runtime.Current.ProcessIds.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task LaunchExceptionAndCleanupFailureRetainOwnedProcessesAndBothFailureDetails()
    {
        var runtime = new CoreConnectionTestRuntime
        { Current = new(CoreRuntimeState.Stopped, null, []), FailLaunch = true, FailStop = true };
        var result = await new CoreConnectionService(runtime).StartAsync("profile-1", default);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.StartFailed);
        await result.Detail!.Contains("launch failed").Should().BeTrue();
        await result.Detail.Contains("stop failed").Should().BeTrue();
        await result.ProcessIds!.Single().Should().BeEqualTo(9);
    }

    [Test]
    public async Task StoppedLabelDoesNotHideAnOwnedChildFromSelectionOrStop()
    {
        var runtime = new CoreConnectionTestRuntime { Current = new(CoreRuntimeState.Stopped, null, [7]) };
        var service = new CoreConnectionService(runtime);
        await (await service.SelectOnlyAsync("new-profile")).Status.Should().BeEqualTo(CoreConnectionStatus.SelectionRequiresStop);
        await runtime.Calls.Contains("select").Should().BeFalse();
        await (await service.StopAsync(default)).Status.Should().BeEqualTo(CoreConnectionStatus.Stopped);
        await runtime.Calls.Contains("stop").Should().BeTrue();
        await runtime.Current.ProcessIds.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task DiagnosticFailuresCannotUndoAHealthyStartOrStop()
    {
        var runtime = new CoreConnectionTestRuntime
        { Current = new(CoreRuntimeState.Stopped, null, []), FailDiagnostics = true };
        var service = new CoreConnectionService(runtime);
        await (await service.StartAsync("profile-1", default)).Status.Should().BeEqualTo(CoreConnectionStatus.Started);
        await runtime.Current.State.Should().BeEqualTo(CoreRuntimeState.Running);
        await runtime.Current.ProcessIds.Single().Should().BeEqualTo(9);
        await (await service.StopAsync(default)).Status.Should().BeEqualTo(CoreConnectionStatus.Stopped);
        await runtime.Current.State.Should().BeEqualTo(CoreRuntimeState.Stopped);
    }

    [Test]
    public async Task FailedDiagnosticSinkCannotSkipFailedLaunchCleanup()
    {
        var runtime = new CoreConnectionTestRuntime
        { Current = new(CoreRuntimeState.Stopped, null, []), FailDiagnostics = true, FailLaunch = true };
        var result = await new CoreConnectionService(runtime).StartAsync("profile-1", default);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.StartFailed);
        await result.Detail.Should().BeEqualTo("launch failed");
        await runtime.Current.ProcessIds.Count.Should().BeEqualTo(0);
        await runtime.Calls.Contains("stop").Should().BeTrue();
    }

    [Test]
    public async Task MissingProfilesAndForeignListenerCannotLaunch()
    {
        var runtime = new CoreConnectionTestRuntime { MissingProfile = true };
        var service = new CoreConnectionService(runtime);
        await (await service.StartAsync("deleted", default)).Status.Should().BeEqualTo(CoreConnectionStatus.ProfileMissing);
        await (await service.StartAsync(null, default)).Status.Should().BeEqualTo(CoreConnectionStatus.NoSelection);
        await runtime.Calls.Contains("stop").Should().BeFalse();
        runtime.MissingProfile = false;
        runtime.Current = new(CoreRuntimeState.Stopped, null, []);
        runtime.OccupiedPort = true;
        await (await service.StartAsync("profile-1", default)).Status.Should().BeEqualTo(CoreConnectionStatus.PortOccupied);
        await runtime.Calls.Contains("launch").Should().BeFalse();
    }
}

// Implements only the runtime port; all ordering and outcomes execute the same
// application service used by HTTP, settings recovery and module updates.
internal sealed class CoreConnectionTestRuntime : ICoreConnectionRuntime
{
    public CoreConnectionState Current { get; set; } = new(CoreRuntimeState.Running, "profile-1", [7]);
    public bool FailDiagnostics;
    public bool RejectPreflight, ThrowPreflight, FailStop, FailLaunch, MissingProfile, OccupiedPort;
    public bool ListenerReady = true, OwnChildAfterLaunch = true, CleanupTokenCanBeCanceled;
    public CancellationTokenSource? CancelDuringWait;
    public CoreLaunchPreflightResult? Preflight;
    public ICoreLaunchPlan? LaunchedPlan;
    public List<string> Calls { get; } = [];
    public Task<CoreConnectionProfile?> ResolveProfileAsync(string? id)
    { Calls.Add("resolve"); return Task.FromResult(MissingProfile ? null : new CoreConnectionProfile(id ?? "profile-1")); }
    public Task SelectProfileAsync(string id) { Calls.Add("select"); return Task.CompletedTask; }
    public void ResetConfigurationCache() { Calls.Add("reset-cache"); }
    public Task<ICoreLaunchPlan?> PrepareAsync(CoreConnectionProfile profile)
    {
        Calls.Add("prepare");
        if (ThrowPreflight) throw new InvalidOperationException("preflight failed");
        return Task.FromResult<ICoreLaunchPlan?>(RejectPreflight || Preflight?.Failure is not null ? null
            : new TestPlan(profile.Id, Preflight));
    }
    public Task<bool> IsPortOccupiedAsync(ICoreLaunchPlan plan, CancellationToken token) => Task.FromResult(OccupiedPort);
    public void SetTransition(CoreRuntimeState state) => Current = Current with { State = state };
    public void SetStopped() => Current = new(CoreRuntimeState.Stopped, null, []);
    public void SetStarting(ICoreLaunchPlan plan) => Current = new(CoreRuntimeState.Starting, plan.ProfileId, []);
    public void SetRunning() => Current = Current with { State = CoreRuntimeState.Running };
    public void SetFaulted(string detail) => Current = Current with { State = CoreRuntimeState.Faulted };
    public Task StopMonitorAsync() { Calls.Add("stop-monitor"); return Task.CompletedTask; }
    public Task StopAndConfirmAsync(CancellationToken token)
    {
        Calls.Add("stop"); CleanupTokenCanBeCanceled = token.CanBeCanceled;
        token.ThrowIfCancellationRequested();
        if (FailStop) throw new InvalidOperationException("stop failed");
        Current = Current with { ProcessIds = [] };
        return Task.CompletedTask;
    }
    public Task LaunchAsync(ICoreLaunchPlan plan)
    {
        Calls.Add("launch"); LaunchedPlan = plan;
        Current = Current with { ProcessIds = OwnChildAfterLaunch ? [9] : [] };
        if (FailLaunch) throw new InvalidOperationException("launch failed");
        return Task.CompletedTask;
    }
    public Task<bool> WaitForListenerAsync(ICoreLaunchPlan plan, CancellationToken token)
    {
        Calls.Add("listen"); CancelDuringWait?.Cancel(); token.ThrowIfCancellationRequested();
        return Task.FromResult(ListenerReady);
    }
    public Task StartMonitorAsync() { Calls.Add("start-monitor"); return Task.CompletedTask; }
    public Task PublishStatusAsync() { Calls.Add("publish"); return FailDiagnostics ? Task.FromException(new Exception("status sink closed")) : Task.CompletedTask; }
    public void Log(string message) { if (FailDiagnostics) throw new Exception("log sink closed"); }
    internal sealed record TestPlan(string ProfileId, CoreLaunchPreflightResult? Preflight) : ICoreLaunchPlan
    { public int ProxyPort => 10808; }
}
