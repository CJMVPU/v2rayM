namespace V2rayM.Application.Subscriptions;

public enum SubscriptionUpdateStatus { Succeeded, Failed, Skipped }
public sealed record SubscriptionUpdateResult(string Id, SubscriptionUpdateStatus Status);

public interface ISubscriptionUpdater
{
    // Some upstream download operations are not cancellable. The operation lease must
    // remain owned until they finish; cancellation is checked before committing metadata.
    Task<IReadOnlyList<SubscriptionUpdateResult>> UpdateAsync(string id, bool useProxy, Func<bool, string, Task> progress);
    Task SaveConfigurationAsync();
    Task StampAsync(string id, long unixTime);
}

public interface ISubscriptionUpdateEvents
{
    Task ProgressAsync(string id, bool success, string message);
    void Changed(string id);
    void Failed(Exception exception);
}

public sealed class SubscriptionUpdateService(IOperationScope operations, IMutationScope mutations,
    ISubscriptionUpdater updater, ISubscriptionUpdateEvents events, TimeProvider clock)
{
    private readonly object _gate = new();
    private readonly Dictionary<string, Task> _tasks = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> _retryAfter = new(StringComparer.Ordinal);

    public bool CanAutoUpdate(string id)
    {
        lock (_gate)
        {
            if (!_retryAfter.TryGetValue(id, out var due)) return true;
            if (clock.GetUtcNow() < due) return false;
            _retryAfter.Remove(id);
            return true;
        }
    }

    public IReadOnlyList<string> Running()
    {
        lock (_gate) return _tasks.Keys.ToArray();
    }

    public Task? TryStart(string id, bool useProxy, CancellationToken token)
    {
        lock (_gate)
        {
            if (operations.IsStopping || token.IsCancellationRequested ||
                _tasks.Keys.Any(key => key.Length == 0 || id.Length == 0 || key == id)) return null;
            var task = Task.Run(async () =>
            {
                try
                {
                    await operations.RunAsync(async operationToken =>
                    {
                        var updated = await mutations.RunAsync(async () =>
                        {
                            var outcomes = await updater.UpdateAsync(id, useProxy, (success, message) => events.ProgressAsync(id, success, message));
                            ThrowIfStopping(operationToken);
                            lock (_gate)
                            {
                                // Backoff is attempt state, not a successful-update timestamp.
                                // Explicit user retries remain available immediately.
                                var now = clock.GetUtcNow();
                                foreach (var stale in _retryAfter.Where(pair => pair.Value <= now).Select(pair => pair.Key).ToArray())
                                    _retryAfter.Remove(stale);
                                foreach (var outcome in outcomes)
                                {
                                    if (outcome.Status == SubscriptionUpdateStatus.Succeeded) _retryAfter.Remove(outcome.Id);
                                    else _retryAfter[outcome.Id] = now.AddMinutes(5);
                                }
                            }
                            var successful = outcomes.Where(value => value.Status == SubscriptionUpdateStatus.Succeeded)
                                .Select(value => value.Id).Distinct(StringComparer.Ordinal).ToArray();
                            if (successful.Length == 0) return false;
                            await updater.SaveConfigurationAsync();
                            foreach (var successfulId in successful)
                            {
                                ThrowIfStopping(operationToken);
                                await updater.StampAsync(successfulId, clock.GetUtcNow().ToUnixTimeSeconds());
                            }
                            return true;
                        }, operationToken);
                        ThrowIfStopping(operationToken);
                        if (updated) events.Changed(id);
                    }, token);
                }
                catch (OperationCanceledException) when (operations.IsStopping || token.IsCancellationRequested) { }
                catch (Exception exception) { events.Failed(exception); }
                finally { lock (_gate) _tasks.Remove(id); }
            });
            _tasks.Add(id, task);
            return task;
        }
    }
    private void ThrowIfStopping(CancellationToken token)
    {
        // Linked-token cancellation may be dispatched asynchronously. Admission's
        // stopping state is authoritative before committing update metadata.
        if (operations.IsStopping) throw new OperationCanceledException(operations.ShutdownToken);
        token.ThrowIfCancellationRequested();
    }

}
