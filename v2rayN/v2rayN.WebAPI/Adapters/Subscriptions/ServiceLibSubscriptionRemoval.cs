using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using V2rayM.Application.Subscriptions;

namespace v2rayN.WebAPI.Adapters.Subscriptions;

internal sealed class ServiceLibSubscriptionRemoval(Func<Config> config, Func<string?> runningProfile,
    Func<Task> save) : ISubscriptionRemovalRepository
{
    public async Task<SubscriptionRemovalPlan> PlanAsync(string id)
    {
        if (await ConfigDbQuery.GetSubItem(id) is null) return new(false, false, false);
        var selected = await ConfigDbQuery.GetProfileItem(config().IndexId);
        var runningId = runningProfile();
        var running = string.IsNullOrEmpty(runningId) ? null : await ConfigDbQuery.GetProfileItem(runningId);
        return new(true, selected?.Subid == id, running?.Subid == id);
    }
    public async Task DeleteAsync(string id, bool resetSelection)
    {
        if (await ConfigDbHandler.DeleteSubItem(config(), id) != 0)
            throw new IOException("ServiceLib could not delete the subscription.");
        if (resetSelection) _ = await ConfigTextHandler.GetDefaultServer(config());
        // Deleting the selected group also changes SubIndexId without removing the active profile.
        await save();
    }
}
