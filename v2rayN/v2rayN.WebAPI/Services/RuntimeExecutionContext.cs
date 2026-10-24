namespace v2rayN.WebAPI.Services;

/// One runtime owns these gates. Services share this context; extracting a service
/// must never create a second core/config lock. Order: operation lease, core, mutation.
internal sealed class RuntimeExecutionContext(RuntimeOperationCoordinator operations)
{
    public RuntimeOperationCoordinator Operations { get; } = operations;
    public RuntimeMutationGate Mutations { get; } = new();
    public SemaphoreSlim CoreGate { get; } = new(1, 1);
    public SemaphoreSlim RegionalPresetGate { get; } = new(1, 1);

    public async Task<T> WithCoreAsync<T>(Func<Task<T>> action, CancellationToken token)
    {
        await CoreGate.WaitAsync(token);
        try { return await action(); }
        finally { CoreGate.Release(); }
    }
}
