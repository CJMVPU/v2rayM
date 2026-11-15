using System.Collections.Concurrent;
using ServiceLib.Models.Dto;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

/// Owns update admission, task lifetime and progress. Single/batch paths use the
/// same typed check decision before they are allowed to stage any executable.
internal sealed class ModuleUpdateCoordinator(RuntimeExecutionContext execution)
{
    private readonly V2rayM.Application.Updates.ModuleUpdateTasks _tasks = new(execution.Operations);
    public ConcurrentDictionary<string, CoreUpdateProgressView> Progress { get; } = new(StringComparer.Ordinal);
    public bool TryStart(string name, Action queued, Func<Task> operation) => _tasks.TryStart(name, queued, operation);
    public Task? GetTask(string name) => _tasks.GetTask(name);
    public IReadOnlyList<string> RunningOperations() => _tasks.RunningOperations();

    public static CoreUpdateCheckResult Classify(UpdateResult result, bool isUpToDate)
    {
        // Translate explicitly: persisted/upstream enum numbers are not domain identity.
        var upstream = result.Decision;
        V2rayM.Domain.Updates.UpdateDecision? requested = upstream switch
        {
            null => null,
            UpdateCheckDecision.Current => V2rayM.Domain.Updates.UpdateDecision.Current,
            UpdateCheckDecision.Available => V2rayM.Domain.Updates.UpdateDecision.Available,
            UpdateCheckDecision.AwaitingValidation => V2rayM.Domain.Updates.UpdateDecision.AwaitingValidation,
            _ => V2rayM.Domain.Updates.UpdateDecision.Failed,
        };
        var admitted = V2rayM.Domain.Updates.UpdateAdmission.Decide(requested, isUpToDate,
            result.Success, result.Version is not null, !string.IsNullOrWhiteSpace(result.Url));
        var decision = admitted switch
        {
            V2rayM.Domain.Updates.UpdateDecision.Current => UpdateCheckDecision.Current,
            V2rayM.Domain.Updates.UpdateDecision.Available => UpdateCheckDecision.Available,
            V2rayM.Domain.Updates.UpdateDecision.AwaitingValidation => UpdateCheckDecision.AwaitingValidation,
            _ => UpdateCheckDecision.Failed,
        };
        return new(result, decision);
    }
}

internal sealed record CoreUpdateCheckResult(UpdateResult Result, UpdateCheckDecision Decision)
{
    public bool IsUpToDate => Decision == UpdateCheckDecision.Current;
    public bool AwaitingValidation => Decision == UpdateCheckDecision.AwaitingValidation;
    public bool CanStage => Decision == UpdateCheckDecision.Available;
}
