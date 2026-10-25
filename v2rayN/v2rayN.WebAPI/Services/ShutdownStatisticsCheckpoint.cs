namespace v2rayN.WebAPI.Services;

/// Save already observed counters before a potentially failing/slow core stop.
/// SaveTo owns its snapshot/write locks. Timing out our wait does not cancel that
/// write, so a second barrier keeps later database shutdown behind its completion.
internal sealed class ShutdownStatisticsCheckpoint(
    Func<Task> save,
    Action<string> log,
    TimeSpan captureBudget)
{
    private Task? _saveTask;

    public static ShutdownCleanupStep[] WrapCoreStop(
        Func<Task> save,
        Func<ShutdownDeadline, Task<bool>> stopCore,
        Action<string> log,
        TimeSpan? captureBudget = null)
    {
        var checkpoint = new ShutdownStatisticsCheckpoint(save, log, captureBudget ?? TimeSpan.FromSeconds(2));
        return [
            new("statistics checkpoint", checkpoint.CaptureAsync),
            new("Core stop", stopCore),
            new("statistics checkpoint drain", checkpoint.DrainAsync),
        ];
    }

    private async Task<bool> CaptureAsync(ShutdownDeadline deadline)
    {
        // Preserve most of the remaining shutdown budget for core cleanup, even
        // when operation draining consumed most of the original budget.
        var budget = TimeSpan.FromTicks(Math.Max(1, Math.Min(captureBudget.Ticks, deadline.Remaining.Ticks / 4)));
        _saveTask = Task.Run(async () =>
        {
            try { await save(); }
            catch (Exception exception)
            {
                // Observe late failures too if Core stop subsequently aborts the
                // sequence. A failed checkpoint must never prevent Core cleanup.
                LogFailure($"Shutdown statistics checkpoint failed: {exception.Message}; Core cleanup will continue.");
            }
        });
        try { await _saveTask.WaitAsync(budget, deadline.Token); }
        catch (TimeoutException)
        {
            LogFailure("Shutdown statistics checkpoint exceeded its short wait budget; Core cleanup will continue, and database close must wait for the pending write.");
        }
        return true;
    }

    private async Task<bool> DrainAsync(ShutdownDeadline deadline)
    {
        if (_saveTask is not null) await _saveTask.WaitAsync(deadline.Remaining, deadline.Token);
        return true;
    }

    private void LogFailure(string message)
    {
        try { log(message); }
        catch (Exception)
        {
            // Logging may itself lose its output pipe during host shutdown.
            // Diagnostics must not turn a best-effort save into a Core-stop gate.
        }
    }
}
