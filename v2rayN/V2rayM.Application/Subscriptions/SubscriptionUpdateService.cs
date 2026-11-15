namespace V2rayM.Application.Subscriptions;

public interface ISubscriptionUpdater
{
    // Some upstream download operations are not cancellable. The operation lease must
    // remain owned until they finish; cancellation is checked before committing metadata.
    Task UpdateAsync(string id, bool useProxy, Func<bool, string, Task> progress);
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
                        await mutations.RunAsync(async () =>
                        {
                            await updater.UpdateAsync(id, useProxy, (success, message) => events.ProgressAsync(id, success, message));
                            ThrowIfStopping(operationToken);
                            await updater.SaveConfigurationAsync();
                            ThrowIfStopping(operationToken);
                            await updater.StampAsync(id, clock.GetUtcNow().ToUnixTimeSeconds());
                            return true;
                        }, operationToken);
                        ThrowIfStopping(operationToken);
                        events.Changed(id);
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
