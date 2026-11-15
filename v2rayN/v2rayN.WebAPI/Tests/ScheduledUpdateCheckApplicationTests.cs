using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class ScheduledUpdateCheckApplicationTests
{
    [Test]
    public async Task SlowNetworkDoesNotHoldMutationOrMaintenanceLeaseAndChangedSettingsDiscardResult()
    {
        var runtime = new Runtime();
        var task = new ScheduledUpdateCheckService(runtime).RunAsync(default);
        await runtime.NetworkStarted.Task.WaitAsync(TimeSpan.FromSeconds(3));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        await using (var settings = await runtime.Operations.EnterExclusiveAsync(timeout.Token))
        {
            await runtime.Mutations.RunAsync(() => { runtime.Current = runtime.Current with { UseProxy = false }; return Task.CompletedTask; });
        }
        runtime.NetworkRelease.SetResult();
        await task;
        await runtime.Published.Count.Should().BeEqualTo(0);
        await runtime.CapturedProxy.Should().BeEqualTo(10808);
    }

    [Test]
    public async Task InstalledVersionChangeDuringNetworkInvalidatesAdvisoryResult()
    {
        var runtime = new Runtime();
        var task = new ScheduledUpdateCheckService(runtime).RunAsync(default);
        await runtime.NetworkStarted.Task;
        await using (var update = await runtime.Operations.EnterExclusiveAsync())
            runtime.Current = runtime.Current with { Targets = [new("Xray", false, "2.0.0")] };
        runtime.NetworkRelease.SetResult();
        await task;
        await runtime.Published.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task UnchangedSnapshotPublishesOnlyAfterNetworkFinishes()
    {
        var runtime = new Runtime();
        var task = new ScheduledUpdateCheckService(runtime).RunAsync(default);
        await runtime.NetworkStarted.Task;
        await runtime.Published.Count.Should().BeEqualTo(0);
        runtime.NetworkRelease.SetResult(); await task;
        await runtime.Published.Single().Target.Should().BeEqualTo("Xray");
    }

    [Test]
    public async Task ShutdownWaitsForOutstandingNetworkAndNeverPublishesItsLateResponse()
    {
        using var shutdown = new CancellationTokenSource();
        var runtime = new Runtime();
        var task = new ScheduledUpdateCheckService(runtime).RunAsync(shutdown.Token);
        await runtime.NetworkStarted.Task;
        shutdown.Cancel();
        await task.IsCompleted.Should().BeFalse();
        runtime.NetworkRelease.SetResult();
        var cancelled = false;
        try { await task; } catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await runtime.Published.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task FailedTargetDoesNotSkipOtherTargetsOrPublishPartialBatchEarly()
    {
        var runtime = new Runtime { ThrowFirst = true };
        runtime.Current = runtime.Current with { Targets = [new("First", false, "1.0.0"), new("Second", true, "1.0.0")] };
        runtime.NetworkRelease.SetResult();
        await new ScheduledUpdateCheckService(runtime).RunAsync(default);
        await runtime.Published.Count.Should().BeEqualTo(2);
        await runtime.Published[0].Available.Should().BeFalse();
        await runtime.Published[1].Available.Should().BeTrue();
    }

    [Test]
    public async Task ProxyPortChangeInvalidatesOnlyProxyDependentPlan()
    {
        var plan = new ScheduledUpdatePlan(true, [new("Xray", false, "1.0.0")], 10808);
        await plan.Matches(plan with { ProxyPort = 20808 }).Should().BeFalse();
        await (plan with { UseProxy = false }).Matches(plan with { UseProxy = false, ProxyPort = 20808 }).Should().BeTrue();
        await plan.Matches(plan with { Targets = [] }).Should().BeFalse();
        await plan.Matches(plan with { Targets = [new("Xray", true, "1.0.0")] }).Should().BeFalse();
    }

    private sealed class Runtime : IScheduledUpdateCheck
    {
        public RuntimeOperationCoordinator Operations = new();
        public RuntimeMutationGate Mutations = new();
        public ScheduledUpdatePlan Current = new(true, [new("Xray", false, "1.0.0")], 10808);
        public List<ScheduledUpdateResult> Published = [];
        public TaskCompletionSource NetworkStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource NetworkRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int CapturedProxy;
        public bool ThrowFirst;
        public async Task<ScheduledUpdatePlan> CaptureAsync(CancellationToken token)
        {
            await using var lease = await Operations.EnterOperationAsync(token);
            return await Mutations.RunAsync(() => Task.FromResult(Current), lease.Token);
        }
        public async Task<ScheduledUpdateResult> CheckRemoteAsync(ScheduledUpdateTarget target, bool proxy, int proxyPort, CancellationToken token)
        {
            CapturedProxy = proxyPort;
            NetworkStarted.TrySetResult();
            await NetworkRelease.Task; // A slow upstream call need not observe cancellation promptly.
            if (ThrowFirst && target.Id == "First") throw new IOException("unavailable");
            return new(target.Id, true, "new version");
        }
        public async Task<bool> TryPublishAsync(ScheduledUpdatePlan captured, IReadOnlyList<ScheduledUpdateResult> results, CancellationToken token)
        {
            await using var lease = await Operations.EnterOperationAsync(token);
            return await Mutations.RunAsync(() =>
            {
                if (!captured.Matches(Current)) return Task.FromResult(false);
                Published.AddRange(results); return Task.FromResult(true);
            }, lease.Token);
        }
        public void Log(string message) => throw new IOException("log unavailable");
    }
}
