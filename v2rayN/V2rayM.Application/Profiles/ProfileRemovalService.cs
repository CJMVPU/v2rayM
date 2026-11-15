using V2rayM.Domain.Profiles;

namespace V2rayM.Application.Profiles;

public sealed record ProfileRemovalPlan(IReadOnlyList<string> ExistingIds, string? SelectedId,
    string? RunningId, bool WasRunning, bool HasActiveProcesses);
public interface IProfileRemovalRepository
{
    Task<ProfileRemovalPlan> PlanAsync(IReadOnlyList<string> ids);
    Task<string?> DeleteAsync(IReadOnlyList<string> ids, bool resetSelection);
    string SelectedGroup { get; }
}
public enum ProfileRemovalStatus { Deleted, SelectionRequired, NotFound, StopFailed, RestartFailed }
public sealed record ProfileRemovalResult(ProfileRemovalStatus Status, int Count = 0, bool Restarted = false);

/// Lifecycle serialization is owned by the caller across stop, mutation and restart.
/// Restart runs outside the mutation scope because core startup also reads/writes configuration.
public sealed class ProfileRemovalService(IProfileRemovalRepository repository, IMutationScope mutations,
    IProfileCatalogEvents events)
{
    public async Task<ProfileRemovalResult> DeleteAsync(IEnumerable<string> profileIds,
        Func<Task<bool>> stop, Func<Task<bool>> restart)
    {
        var ids = ProfileSelection.Normalize(profileIds);
        if (ids.Length == 0) return new(ProfileRemovalStatus.SelectionRequired);
        var shouldRestart = false;
        var result = await mutations.RunAsync(async () =>
        {
            var plan = await repository.PlanAsync(ids);
            if (plan.ExistingIds.Count == 0) return new ProfileRemovalResult(ProfileRemovalStatus.NotFound);
            var removesSelected = plan.SelectedId is { } selected && plan.ExistingIds.Contains(selected);
            var removesRunning = plan.ExistingIds.Contains(plan.RunningId ?? plan.SelectedId ?? string.Empty);
            if (removesRunning && (plan.WasRunning || plan.HasActiveProcesses) && !await stop())
                return new ProfileRemovalResult(ProfileRemovalStatus.StopFailed);
            var next = await repository.DeleteAsync(plan.ExistingIds, removesSelected || removesRunning);
            shouldRestart = removesRunning && plan.WasRunning && !string.IsNullOrEmpty(next);
            return new ProfileRemovalResult(ProfileRemovalStatus.Deleted, plan.ExistingIds.Count);
        });
        if (result.Status != ProfileRemovalStatus.Deleted) return result;
        if (shouldRestart)
        {
            var started = await restart();
            result = result with { Status = started ? ProfileRemovalStatus.Deleted : ProfileRemovalStatus.RestartFailed, Restarted = started };
        }
        events.Changed(repository.SelectedGroup);
        return result;
    }
}
