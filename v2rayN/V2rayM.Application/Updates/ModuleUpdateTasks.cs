namespace V2rayM.Application.Updates;

/// Shared lifetime/admission for single, batch and scheduled module updates.
public sealed class ModuleUpdateTasks(IOperationScope operations)
{
    private readonly object _sync = new();
    private readonly Dictionary<string, Task> _tasks = new(StringComparer.Ordinal);

    public bool TryStart(string name, Action queued, Func<Task> operation)
    {
        lock (_sync)
        {
            if (operations.IsStopping || _tasks.Values.Any(task => !task.IsCompleted)) return false;
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

}
