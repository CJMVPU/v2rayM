namespace V2rayM.Application;

public interface IOperationScope
{
    bool IsStopping { get; }
    CancellationToken ShutdownToken { get; }
    Task RunAsync(Func<CancellationToken, Task> operation, CancellationToken cancellationToken);
}
