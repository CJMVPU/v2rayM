namespace V2rayM.Application.Subscriptions;

public sealed record SubscriptionRemovalPlan(bool Exists, bool RemovesSelectedProfile, bool RemovesRunningProfile);
public interface ISubscriptionRemovalRepository
{
    Task<SubscriptionRemovalPlan> PlanAsync(string id);
    Task DeleteAsync(string id, bool resetSelection);
}
public enum SubscriptionRemovalResult { Deleted, NotFound, StopFailed }

/// Caller owns the lifecycle gate before entering the shared mutation scope.
/// Deletion must never proceed if the owned core could not be stopped.
public sealed class SubscriptionRemovalService(ISubscriptionRemovalRepository repository, IMutationScope mutations)
{
    public Task<SubscriptionRemovalResult> DeleteAsync(string id, Func<Task<bool>> stopCore,
        CancellationToken token = default) => mutations.RunAsync(async () =>
    {
        var plan = await repository.PlanAsync(id);
        if (!plan.Exists) return SubscriptionRemovalResult.NotFound;
        if ((plan.RemovesSelectedProfile || plan.RemovesRunningProfile) && !await stopCore())
            return SubscriptionRemovalResult.StopFailed;
        await repository.DeleteAsync(id, plan.RemovesSelectedProfile);
        return SubscriptionRemovalResult.Deleted;
    }, token);
}
