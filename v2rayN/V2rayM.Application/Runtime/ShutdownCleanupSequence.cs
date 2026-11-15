namespace V2rayM.Application.Runtime;

public static class RuntimeShutdownBudgets
{
    // Runtime cleanup owns 20 seconds; the host retains 5 seconds, systemd is
    // configured to 30 seconds, and the native --stop launcher waits 5 seconds more.
    public static readonly TimeSpan RuntimeCleanup = TimeSpan.FromSeconds(20);

    public static readonly TimeSpan HostShutdown = TimeSpan.FromSeconds(25);
    public static readonly TimeSpan LauncherWait = TimeSpan.FromSeconds(35);

    // Used when the host shutdown budget was already exhausted before cleanup
    // started, for example while the web server drained long-lived connections.
    public static readonly TimeSpan LateCleanup = TimeSpan.FromSeconds(5);
}

public sealed class ShutdownDeadline : IDisposable
{
    private readonly TimeSpan _budget;
    private readonly long _started = TimeProvider.System.GetTimestamp();
    private readonly CancellationTokenSource _deadlineCancellation;
    private readonly CancellationTokenSource _linkedCancellation;
    private int _disposed;

    public ShutdownDeadline(TimeSpan budget, CancellationToken cancellationToken)
    {
        if (budget <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(budget));
        }

        _budget = budget;
        _deadlineCancellation = new CancellationTokenSource(budget);
        _linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            _deadlineCancellation.Token);
        Token = _linkedCancellation.Token;
    }

    public CancellationToken Token { get; }

    public TimeSpan Remaining
    {
        get
        {
            var remaining = _budget - TimeProvider.System.GetElapsedTime(_started);
            return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        // A timed-out step can still be unwinding. Keep its token usable and
        // signal cancellation before releasing the timer/registration resources.
        // CancelAsync sets the token state immediately, but a blocking user
        // callback cannot hold the shutdown caller beyond its deadline.
        _ = CancelAndDisposeAsync();
    }

    private async Task CancelAndDisposeAsync()
    {
        try { await _linkedCancellation.CancelAsync(); }
        catch (AggregateException) { /* Observe callback failures without aborting disposal. */ }
        finally
        {
            _linkedCancellation.Dispose();
            _deadlineCancellation.Dispose();
        }
    }
}

public sealed record ShutdownCleanupStep(
    string Name,
    Func<ShutdownDeadline, Task<bool>> ExecuteAsync);

public static class ShutdownCleanupSequence
{
    public static async Task<bool> RunAsync(
        IEnumerable<ShutdownCleanupStep> steps,
        TimeSpan budget,
        CancellationToken cancellationToken,
        Action<string> log,
        Action<string?>? stageChanged = null)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            // The host token can already be canceled when cleanup starts, for
            // example while the web server drains long-lived stream connections.
            // Cleanup is still worth a short, fresh window: it stops the Core
            // child and saves shared state instead of skipping both.
            log("Shutdown started after the host shutdown budget was exhausted; running a reduced cleanup with a fresh budget.");
            budget = RuntimeShutdownBudgets.LateCleanup;
            cancellationToken = CancellationToken.None;
        }

        using var deadline = new ShutdownDeadline(budget, cancellationToken);
        foreach (var step in steps)
        {
            var remaining = deadline.Remaining;
            if (remaining <= TimeSpan.Zero)
            {
                log($"Shutdown deadline expired before '{step.Name}'; all later cleanup was skipped.");
                return false;
            }

            stageChanged?.Invoke(step.Name);
            try
            {
                // Run the synchronous prefix on the thread pool too, so a blocking cleanup
                // implementation cannot prevent the overall deadline from being enforced.
                var execution = Task.Run(async () => await step.ExecuteAsync(deadline));
                var completed = await execution.WaitAsync(remaining, deadline.Token);
                if (!completed)
                {
                    log($"Shutdown stopped at '{step.Name}'; all later cleanup was skipped.");
                    return false;
                }
                stageChanged?.Invoke(null);
            }
            catch (TimeoutException)
            {
                log($"Shutdown deadline expired during '{step.Name}'; all later cleanup was skipped.");
                return false;
            }
            catch (OperationCanceledException) when (deadline.Token.IsCancellationRequested)
            {
                log($"Shutdown was canceled during '{step.Name}'; all later cleanup was skipped.");
                return false;
            }
            catch (Exception exception)
            {
                log($"Shutdown cleanup failed at '{step.Name}': {exception.Message}; all later cleanup was skipped.");
                return false;
            }
        }

        stageChanged?.Invoke(null);
        return true;
    }
}
