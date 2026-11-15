namespace ServiceLib.Tests.Services;

public class DownloadProgressPumpTests
{
    [Test]
    public async Task CompletionWaitsForCallbacksAndPreservesTheirOrder()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var seen = new List<string>();
        var run = Run((report, _) =>
        {
            report("first");
            report("final");
            return Task.CompletedTask;
        }, async message =>
        {
            if (message == "first") { entered.SetResult(); await release.Task; }
            seen.Add(message);
        });
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var completedEarly = run.IsCompleted;
        release.SetResult();
        await run.WaitAsync(TimeSpan.FromSeconds(5));
        await completedEarly.Should().BeFalse();
        await string.Join(",", seen).Should().BeEqualTo("first,final");
    }

    [Test]
    public async Task CallbackFailureCancelsProducerAndIsObserved()
    {
        var cancelled = false;
        var failure = new InvalidOperationException("callback failed");
        Exception? observed = null;
        try
        {
            await Run(async (report, token) =>
            {
                report("sample");
                try { await Task.Delay(Timeout.Infinite, token); }
                catch (OperationCanceledException) { cancelled = true; throw; }
            }, _ => Task.FromException(failure)).WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (Exception exception) { observed = exception; }
        await ReferenceEquals(observed, failure).Should().BeTrue();
        await cancelled.Should().BeTrue();
    }

    [Test]
    public async Task CancellationWaitsForAnInFlightCallback()
    {
        using var cancellation = new CancellationTokenSource();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var run = Run(async (report, token) =>
        {
            report("sample");
            await Task.Delay(Timeout.Infinite, token);
        }, async _ => { entered.SetResult(); await release.Task; }, cancellation.Token);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellation.Cancel();
        var completedEarly = run.IsCompleted;
        release.SetResult();
        var cancelled = false;
        try { await run.WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (OperationCanceledException) { cancelled = true; }
        await completedEarly.Should().BeFalse();
        await cancelled.Should().BeTrue();
    }

    [Test]
    public async Task SlowConsumerKeepsBoundedSnapshotsAndTheFinalValue()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var seen = new List<string>();
        await Run(async (report, _) =>
        {
            report("first");
            await entered.Task;
            for (var index = 0; index < 100; index++) report(index.ToString());
            report("final");
            release.SetResult();
        }, async message =>
        {
            if (message == "first") { entered.SetResult(); await release.Task; }
            seen.Add(message);
        }).WaitAsync(TimeSpan.FromSeconds(5));
        await seen.Count.Should().BeLessThanOrEqualTo(17);
        await seen[0].Should().BeEqualTo("first");
        await seen[^1].Should().BeEqualTo("final");
    }

    private static Task Run(Func<Action<string>, CancellationToken, Task> download,
        Func<string, Task> report, CancellationToken cancellation = default)
    {
        var type = typeof(DownloadService).Assembly.GetType("ServiceLib.Services.DownloadProgressPump")!;
        return (Task)type.GetMethod("RunAsync")!.Invoke(null, [download, report, cancellation])!;
    }
}
