using System.Collections.Concurrent;
using ServiceLib.Models.Dto;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

/// Owns update admission, task lifetime and progress. Single/batch paths use the
/// same typed check decision before they are allowed to stage any executable.
internal sealed class ModuleUpdateCoordinator(RuntimeExecutionContext execution)
{
    private readonly object _sync = new();
    private readonly Dictionary<string, Task> _tasks = new(StringComparer.Ordinal);
    public ConcurrentDictionary<string, CoreUpdateProgressView> Progress { get; } = new(StringComparer.Ordinal);

    public bool TryStart(string name, Action queued, Func<Task> operation)
    {
        lock (_sync)
        {
            if (execution.Operations.IsStopping || _tasks.Values.Any(task => !task.IsCompleted)) return false;
            queued();
            _tasks[name] = Task.Run(async () =>
            {
                try { await operation(); }
                finally { lock (_sync) _tasks.Remove(name); }
            });
            return true;
        }
    }
    public Task? GetTask(string name) { lock (_sync) return _tasks.GetValueOrDefault(name); }
    public IReadOnlyList<string> RunningOperations()
    {
        lock (_sync) return _tasks.Where(pair => !pair.Value.IsCompleted).Select(pair => pair.Key).ToArray();
    }

    public static CoreUpdateCheckResult Classify(UpdateResult result, bool isUpToDate)
    {
        var decision = result.Decision ?? (isUpToDate ? UpdateCheckDecision.Current
            : result.Success && result.Version is not null && !string.IsNullOrWhiteSpace(result.Url)
                ? UpdateCheckDecision.Available : UpdateCheckDecision.Failed);
        // A malformed available result must never authorize package staging.
        if (decision == UpdateCheckDecision.Available &&
            (!result.Success || result.Version is null || string.IsNullOrWhiteSpace(result.Url)))
            decision = UpdateCheckDecision.Failed;
        return new(result, decision);
    }
}

internal sealed record CoreUpdateCheckResult(UpdateResult Result, UpdateCheckDecision Decision)
{
    public bool IsUpToDate => Decision == UpdateCheckDecision.Current;
    public bool AwaitingValidation => Decision == UpdateCheckDecision.AwaitingValidation;
    public bool CanStage => Decision == UpdateCheckDecision.Available;
}
