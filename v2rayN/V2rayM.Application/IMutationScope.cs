namespace V2rayM.Application;

/// One shared serialization scope for reads participating in a mutation and its writes.
/// This is not a database transaction and does not promise rollback of external effects.
public interface IMutationScope
{
    Task<T> RunAsync<T>(Func<Task<T>> mutation, CancellationToken cancellationToken = default);
}
